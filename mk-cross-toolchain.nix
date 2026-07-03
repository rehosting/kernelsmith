# mkCrossToolchain: build one (arch x tool-version) cross toolchain via
# musl-cross-make, fully offline (sources staged from sources.nix).
#
# Returns a derivation whose $out is a self-contained /opt/cross-style toolchain
# rooted at $out/bin/<target>-{gcc,ld,...}, matching what _in_container_build.sh
# and the embedded-toolchains image expect on PATH.
{ pkgs, mcmSrc, sources }:

{
  # mcm TARGET triple, e.g. "arm-linux-musleabi", "mips64-linux-musl"
  target,
  # human label for the derivation name, e.g. "armel"
  name ? target,
  # component versions — keys must exist in sources.nix
  gccVer,
  binutilsVer,
  muslVer,
  gmpVer,
  mpcVer,
  mpfrVer,
  linuxVer ? null, # null -> let mcm pick its bundled default
  # extra config.mak lines (per-arch quirks, e.g. mips -mfix, soft-float)
  extraConfig ? [ ],
  # languages to enable; kernel/modules only need c, userland wants c,c++
  languages ? "c,c++",
}:

let
  inherit (pkgs) lib stdenv;

  # gcc/binutils from the gcc-4.x era ship a config.sub/config.guess that predate
  # musl and reject our `*-linux-musl*` target triples ("config.sub <triple>
  # failed"). mcm normally refreshes them from savannah at build time, but that
  # is a network step the offline sandbox skips — so we refresh them ourselves
  # (from nixpkgs' gnu-config) for the old era only, leaving gcc>=5 cells (whose
  # bundled config.sub already knows musl) byte-for-byte unchanged.
  needsConfigSubUpdate = lib.versionOlder gccVer "5";

  # Appended to litecross/Makefile for the gcc-4.x era: make libgcc depend on the
  # kernel headers being staged into the BUILD sysroot first. gcc 4.x's MIPS
  # libgcc (md-unwind-support.h) `#include <asm/unistd.h>`, but mcm otherwise
  # installs kernel headers too late (only into the OUTPUT sysroot, after libgcc)
  # -> "asm/unistd.h: No such file". The added prereq only adds a dependency (no
  # recipe) to the existing libgcc rule. Built as a double-quoted string so `\t`
  # yields the literal tabs Makefile recipes require; `$(...)`/`$@` stay literal.
  # Harmless when LINUX_VER is unset: the `-$(MAKE)` ignores the missing target.
  kernHdrRule = pkgs.writeText "kernelsmith-kernhdr.mk"
    ("\nobj_gcc/$(TARGET)/libgcc/libgcc.a: obj_sysroot/.lc_kernhdrs\n"
     + "obj_sysroot/.lc_kernhdrs: | obj_sysroot/.lc_headers\n"
     + "\t-$(MAKE) obj_kernel_headers/.lc_built && cp -R obj_kernel_headers/staged/include/. obj_sysroot/include/\n"
     + "\ttouch $@\n");

  # The exact set of component tarballs this toolchain needs, keyed by the
  # filename mcm greps for in sources/.
  needed = lib.filterAttrs (n: _: builtins.elem n ([
    "binutils-${binutilsVer}"
    "gcc-${gccVer}"
    "musl-${muslVer}"
    "gmp-${gmpVer}"
    "mpc-${mpcVer}"
    "mpfr-${mpfrVer}"
  ] ++ lib.optional (linuxVer != null) "linux-${linuxVer}")) sources;

  configMak = ''
    TARGET = ${target}
    OUTPUT = $(out)
    GCC_VER = ${gccVer}
    BINUTILS_VER = ${binutilsVer}
    MUSL_VER = ${muslVer}
    GMP_VER = ${gmpVer}
    MPC_VER = ${mpcVer}
    MPFR_VER = ${mpfrVer}
    ${lib.optionalString (linuxVer != null) "LINUX_VER = ${linuxVer}"}
    COMMON_CONFIG += --disable-nls --disable-multilib
    GCC_CONFIG += --enable-languages=${languages} --disable-libquadmath --disable-decimal-float
    ${lib.optionalString needsConfigSubUpdate ''
      # gcc-4.x era, two host-side fixes (COMMON_CONFIG reaches binutils+gcc, and
      # gcc forwards it to the in-tree math libs; musl configures separately so
      # the TARGET libc still gets its shared .so):
      #  - --disable-shared: build in-tree gmp/mpfr/mpc static, else mpc's
      #    configure fails to link a shared mpfr ("libmpfr ... different ABI").
      #  - CXX=-std=gnu++03: gcc 4.9's own C++ source uses constructs removed in
      #    C++17 (e.g. bool operator++ in reload1.c); host gcc 13 defaults to
      #    C++17, so build gcc with the old dialect it was written for.
      COMMON_CONFIG += --disable-shared --enable-static
      COMMON_CONFIG += CXX="g++ -std=gnu++03"
    ''}
    ${lib.concatStringsSep "\n" extraConfig}
  '';

in
stdenv.mkDerivation {
  pname = "cross-${name}-gcc${gccVer}";
  version = gccVer;

  # mcm itself is the "source"; component tarballs are staged in preConfigure.
  src = mcmSrc;

  # Host tools needed to drive the mcm build (the compilers it produces are
  # bootstrapped from the host gcc in nativeBuildInputs).
  nativeBuildInputs = with pkgs; [ gnumake gcc bison flex texinfo gnused gawk which perl file ];

  # Old gcc + modern host glibc headers fight; relax where mcm/gcc are noisy.
  NIX_CFLAGS_COMPILE = "-Wno-error";
  hardeningDisable = [ "format" "fortify" ];
  enableParallelBuilding = true;

  postPatch = ''
    # This mcm master ships 2026-dated musl CVE patches (e.g.
    # cve-2026-40200-old.diff) that apply as fuzzy hunks to musl 1.1.24's
    # qsort.c and corrupt it ("expected identifier before '=='"). They harden
    # the TARGET musl, not the toolchain build, so drop them. (Revisit if guest
    # musl hardening matters; better long-term fix is pinning a stable mcm.)
    rm -f patches/musl-*/cve-*.diff

    # Stage pinned tarballs where mcm expects them, skipping its wget step.
    mkdir -p sources
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (fname: drv: ''cp ${drv} sources/${fname}.tar.${
        # preserve the upstream compression suffix mcm keys on
        if lib.hasSuffix ".tar.xz" drv.name then "xz"
        else if lib.hasSuffix ".tar.bz2" drv.name then "bz2"
        else "gz"
      }'')
      needed)}

    # mcm's dependency graph requires a hashes/<file>.sha1 for every source it
    # extracts (it's a prereq of the download rule). We pre-stage sources so the
    # download+verify never runs, but the file must still EXIST or make errors on
    # the missing prereq. Synthesize any absent entries from the staged tarballs
    # so we can use component versions mcm doesn't bless (e.g. gcc 4.9.4).
    for f in sources/*.tar.*; do
      b=$(basename "$f")
      [ -e "hashes/$b.sha1" ] || printf '%s  %s\n' "$(sha1sum < "$f" | cut -d' ' -f1)" "$b" > "hashes/$b.sha1"
    done
    # Make the staged tarballs newer than their hashes/*.sha1 prereqs, else make
    # deems them out of date and fires mcm's (offline-forbidden) wget download.
    touch sources/*.tar.*

    ${lib.optionalString needsConfigSubUpdate
      "cat ${kernHdrRule} >> litecross/Makefile"}

    cat > config.mak <<'EOF'
    ${configMak}
    EOF
  '';

  # mcm's "install" places the toolchain under $(OUTPUT); we set OUTPUT=$out.
  buildPhase = ''
    runHook preBuild
    ${lib.optionalString needsConfigSubUpdate ''
      # Extract sources first (no build), refresh the pre-musl config.sub/
      # config.guess in the gcc + binutils trees, then build. extract_all only
      # populates $(SRC_DIRS); the subsequent `make` reuses them (order-only
      # prereqs), so it will not re-extract and clobber our refreshed copies.
      make extract_all
      for f in config.sub config.guess; do
        find gcc-${gccVer} binutils-${binutilsVer} -name "$f" \
          -exec cp -f ${pkgs.gnu-config}/$f {} \;
      done
    ''}
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    make install
    runHook postInstall
  '';

  # Sanity check the produced compiler exists and reports the right target.
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/${target}-gcc" --version | head -1
    "$out/bin/${target}-gcc" -dumpmachine | grep -q "${lib.head (lib.splitString "-" target)}"
  '';

  passthru = { inherit target gccVer; };

  meta = {
    description = "musl cross toolchain: ${target} (gcc ${gccVer})";
    platforms = pkgs.lib.platforms.linux;
  };
}
