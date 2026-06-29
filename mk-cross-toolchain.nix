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
  nativeBuildInputs = with pkgs; [ gnumake gcc bison flex texinfo gnused gawk which perl ];

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

    cat > config.mak <<'EOF'
    ${configMak}
    EOF
  '';

  # mcm's "install" places the toolchain under $(OUTPUT); we set OUTPUT=$out.
  buildPhase = ''
    runHook preBuild
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
