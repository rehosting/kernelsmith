# mkKernelToolchain: build one KERNEL-ONLY period-correct gcc for the k2.6 band.
#
# Distinct from the musl userland toolchain in mk-cross-toolchain.nix. The Linux
# kernel is built -nostdinc -ffreestanding and links no target libc (libgcc ships
# inside gcc), so period gcc 4.4.7 (2.6.31's actual-era compiler) suffices without
# the musl-1.1.24-header wall that bars gcc <4.9 as a *musl* compiler. It also
# removes real kernel-source failures: gcc >=4.9 rejects arch/mips/mm/page.c's
# function/variable alias with a HARD error no -Wno-error can touch; 4.4 accepts it.
#
# Two build shapes, selected by `native`:
#
#  * CROSS (native = false, the default) — for every arch whose CPU differs from
#    the x86_64-linux build host (arm, mips, ppc, ...). Plain two-stage build:
#    binutils --target, then gcc --target --without-headers --with-newlib. No libc.
#
#  * NATIVE (native = true) — for x86_64, where target==host. A "cross" with
#    --without-headers hits gcc's native-detection trap (libgcc links against an
#    absent libc), and an -elf triple builds but omits the linux OS predefines that
#    2.6.31's x86 .S files need (ACPICA's __linux__; the asm preprocessing). So we
#    build a genuine NATIVE gcc — it defines __linux__/__x86_64__ correctly and the
#    tree preprocesses as it did in 2009. A native ancient-gcc build under sandboxed
#    nix needs three fixes the native path assumes-away: (1) point fixincludes at
#    the store glibc headers (NATIVE_SYSTEM_HEADER_DIR defaults to the absent
#    /usr/include, and gcc 4.4 has no --with-native-system-header-dir; --with-headers
#    is cross-only, so patch the Makefile.in template); (2) `struct ucontext` ->
#    ucontext_t (glibc >=2.26 dropped the tag; gcc 4.4's unwinder uses it);
#    (3) export CPATH so the in-build xgcc (whose header search is relative to its
#    build-dir location) finds glibc and passes libgcc's AC_PROG_CPP sanity check.
#    binutils is built serial (2.27 has a parallel `mkdir ldscripts` race).
#
# Returns a derivation rooted at $out/bin/<target>-{gcc,ld,...} (native mode
# symlinks those names to the plain native tools), matching buildKernel's PATH.
{ pkgs, sources }:

{
  # kernel CROSS_COMPILE triple, e.g. "mipsel-linux", "arm-linux-gnueabi", or
  # (native) "x86_64-linux". No libc component — musl triples would drag musl in.
  target,
  name ? target,
  gccVer,
  binutilsVer,
  gmpVer,
  mpfrVer,
  # gcc --with-arch (e.g. mips needs mips32r2); null to leave the gcc default.
  withArch ? null,
  # true for x86_64 (target CPU == build host): build a native gcc, not a cross.
  native ? false,
}:

let
  inherit (pkgs) lib stdenv;
  src = n: sources.${n};
  sysHdr = "${pkgs.glibc.dev}/include";
  # `native` cross triple has no explicit --target; gcc/binutils autodetect the
  # host (x86_64-pc-linux-gnu) and install plain tool names we symlink `target-`.
  tgtFlag = lib.optionalString (!native) "--target=${target}";
in
stdenv.mkDerivation {
  pname = "cross-${name}-kernel-gcc${gccVer}";
  version = gccVer;

  srcs = [ (src "binutils-${binutilsVer}") (src "gcc-${gccVer}") (src "gmp-${gmpVer}") (src "mpfr-${mpfrVer}") ];
  sourceRoot = ".";

  nativeBuildInputs = with pkgs; [ gnumake gcc bison flex texinfo gnused gawk which perl file ];
  # Old gcc-era C source vs modern host headers is noisy; don't let it be fatal.
  NIX_CFLAGS_COMPILE = "-Wno-error";
  hardeningDisable = [ "format" "fortify" ];
  enableParallelBuilding = true;

  unpackPhase = ''
    runHook preUnpack
    for s in $srcs; do tar xf "$s"; done
    runHook postUnpack
  '';

  buildPhase = ''
    runHook preBuild
    export PREFIX=$out
    export PATH=$out/bin:$PATH
    # gcc <4.8 is written in gnu89 C; a modern host gcc's gnu11 inline semantics
    # turn system.h's `extern inline` floor_log2/exact_log2 into redefinition
    # errors. Build gcc's own C in the dialect it was written for.
    HOSTCC="gcc -std=gnu89 -fgnu89-inline"

    # gmp/mpfr in-tree so gcc 4.4 builds them itself, fully offline.
    mv gmp-${gmpVer} gcc-${gccVer}/gmp
    mv mpfr-${mpfrVer} gcc-${gccVer}/mpfr
    # Refresh pre-musl config.sub/.guess for host-triple robustness on a modern
    # build machine (harmless for the plain -linux target triples we use here).
    for f in config.sub config.guess; do
      find binutils-${binutilsVer} gcc-${gccVer} -name "$f" -exec cp -f ${pkgs.gnu-config}/$f {} \;
    done

    ${lib.optionalString native ''
      # NATIVE-mode fixups (see header). glibc unwinder tag + fixincludes header
      # dir + in-build header search for the target-libgcc CPP sanity check.
      find gcc-${gccVer}/gcc/config -name 'linux-unwind.h' -exec sed -i 's/struct ucontext\b/ucontext_t/g' {} +
      sed -i 's#^NATIVE_SYSTEM_HEADER_DIR = /usr/include#NATIVE_SYSTEM_HEADER_DIR = ${sysHdr}#' gcc-${gccVer}/gcc/Makefile.in
      export CPATH=${sysHdr}
      export C_INCLUDE_PATH=${sysHdr}
    ''}

    echo "=== binutils (${target}) ==="
    # binutils 2.27 has a parallel `mkdir ldscripts` race; serial in native mode
    # (the extra minutes are cheap and the race is nondeterministic).
    mkdir -p build-binutils && ( cd build-binutils && \
      ../binutils-${binutilsVer}/configure ${tgtFlag} --prefix=$out \
        --disable-nls --disable-werror --disable-multilib && \
      make ${if native then "" else "-j$NIX_BUILD_CORES"} && make install )

    echo "=== gcc (${target}${lib.optionalString native ", native"}) ==="
    # MAKEINFO=true: modern texinfo (7.x) can't render gcc 4.4's .texi docs.
    mkdir -p build-gcc && ( cd build-gcc && \
      CC="$HOSTCC" ../gcc-${gccVer}/configure ${tgtFlag} --prefix=$out \
        --enable-languages=c --disable-shared --disable-nls --disable-multilib \
        --disable-libssp --disable-libgomp --disable-libmudflap --disable-libquadmath --disable-decimal-float \
        ${if native then "--disable-bootstrap" else "--without-headers --with-newlib --disable-threads"} \
        ${lib.optionalString (withArch != null) "--with-arch=${withArch}"} && \
      make MAKEINFO=true -j$NIX_BUILD_CORES ${if native then "" else "all-gcc all-target-libgcc"} )
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ( cd build-gcc && make MAKEINFO=true ${if native then "install" else "install-gcc install-target-libgcc"} )
    ${lib.optionalString native ''
      # Native gcc/binutils install plain tool names (+ x86_64-pc-linux-gnu-*);
      # expose the ${target}- prefix the kernel's CROSS_COMPILE expects.
      cd $out/bin
      for t in gcc cpp gcc-ar gcc-nm gcc-ranlib \
               as ld ar nm objcopy objdump ranlib strip readelf size strings addr2line; do
        [ -e "$t" ] && ln -sf "$t" "${target}-$t" || true
      done
    ''}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/${target}-gcc" --version | head -1
    "$out/bin/${target}-gcc" -dumpmachine
    test -f "$out/lib/gcc/"*/*/libgcc.a && echo "libgcc.a present"
  '';

  passthru = { inherit target gccVer; };
  meta = {
    description = "kernel-only ${target} toolchain (period gcc ${gccVer}${lib.optionalString native ", native"})";
    platforms = pkgs.lib.platforms.linux;
  };
}
