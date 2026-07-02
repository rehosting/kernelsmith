# buildKernel: the unified entrypoint. Give it (version, arch, src, config) and
# it self-selects the right cross toolchain from the matrix via resolve.nix.
#
# This is the "move between kernel versions as targets" piece: the toolchain is
# a *derived* input, not something the caller wires up. Layer 2 over the
# toolchain matrix. The actual kernel-build quirk handling (per-era patches,
# HOSTCC fixups) lives in `eraQuirks` — stubbed here; this is where the inherent
# old-kernel pain accretes as you widen the version range.
{ pkgs, toolchains, resolve }:

{
  version, # e.g. "3.18.140"
  arch, # matrix arch key, e.g. "mipsel"
  src, # kernel source (fetchurl/fetchgit)
  config ? null, # a full .config file (mutually exclusive with defconfig)
  defconfig ? null, # an in-tree config make-target, e.g. "versatile_defconfig"
  archMakeVars ? { }, # ARCH= / CROSS_COMPILE handled below; extra make vars here
  buildModules ? true,
}:
assert (config != null) != (defconfig != null) ||
  throw "buildKernel: pass exactly one of `config` or `defconfig`";

let
  inherit (pkgs) lib stdenv;

  eraName = resolve.eraFor version;
  toolchain = toolchains."${eraName}-${arch}" or (throw
    "buildKernel: no toolchain for era ${eraName} arch ${arch} (kernel ${version})");

  # mcm target triple -> kernel CROSS_COMPILE prefix
  crossPrefix = "${toolchain.target}-";

  # matrix arch key -> kernel ARCH= value
  kernelArch = {
    armel = "arm"; armhf = "arm"; arm64 = "arm64";
    mipseb = "mips"; mipsel = "mips"; mips64eb = "mips"; mips64el = "mips";
    powerpc = "powerpc"; powerpcle = "powerpc";
    powerpc64 = "powerpc"; powerpc64le = "powerpc";
    x86_64 = "x86_64";
  }.${arch} or (throw "buildKernel: no kernel ARCH mapping for ${arch}");

  # Per-era build quirks (old trees fight modern host + cross tools). The theme:
  # a NEWER gcc than a tree was written for invents diagnostics the tree trips on
  # under its own -Werror. We build kernels, we don't lint them, so we demote the
  # anachronistic errors rather than patch each site. Two axes:
  #   KCFLAGS   -> appended to the CROSS (target) compile — for gcc>=5 warnings in
  #                kernel C (unused-but-set-variable, aliased-declaration, ...).
  #   HOSTCFLAGS-> the HOST-tool compile (dtc/objtool/... built with nixpkgs gcc13):
  #                -fcommon undoes gcc>=10's -fno-common default that breaks old
  #                host tools' tentative definitions (dtc's `yylloc`); -Wno-error
  #                clears gcc>=12 host warnings (objtool use-after-free, OpenSSL-3
  #                deprecations). NOTE the semantics flip across eras: pre-4.19
  #                `HOSTCFLAGS` OVERRIDES the tree's host flags (so k3 must restate
  #                the 3.18 defaults), >=4.19 it APPENDS to KBUILD_HOSTCFLAGS.
  # `hostCFlags` is kept OUT of `extraMake` because it can contain spaces (the
  # 3.18 default set restated below), and the build make calls expand $makeFlags
  # unquoted; a spaced value would word-split (e.g. `-O2` misread as make's own
  # `-O`utput-sync). It is threaded in as a single quoted `HOSTCFLAGS=...` token.
  eraQuirks = {
    "k2.6" = { patches = [ ]; extraMake = [ "KBUILD_NOPEDANTIC=1" "KCFLAGS=-Wno-error" ]; hostCFlags = ""; };
    "k3" = { patches = [ ]; extraMake = [ "KCFLAGS=-Wno-error" ];
      # 3.18's `HOSTCFLAGS` OVERRIDES (pre-4.19 semantics), so restate its
      # defaults, then add -fcommon (gcc>=10 -fno-common breaks dtc's `yylloc`)
      # and -Wno-error.
      hostCFlags = "-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon -Wno-error"; };
    # >=4.19 `HOSTCFLAGS` APPENDS to KBUILD_HOSTCFLAGS, so a lone -Wno-error is
    # enough to clear gcc>=12 host warnings (objtool use-after-free, ...).
    "k4" = { patches = [ ]; extraMake = [ ]; hostCFlags = "-Wno-error"; };
    "k6" = { patches = [ ]; extraMake = [ ]; hostCFlags = "-Wno-error"; };
  }.${eraName};

  # Single quoted make token for the (possibly spaced) host flags, or empty.
  hostFlagArg = lib.optionalString (eraQuirks.hostCFlags != "")
    ''"HOSTCFLAGS=${eraQuirks.hostCFlags}"'';

  # Config materialization. A board defconfig target generates .config wholesale
  # (works on every era). A supplied .config needs normalizing against the tree:
  # `olddefconfig` only exists from ~2.6.36, so fall back to piped `oldconfig`
  # on the k2.6 band.
  configCmd =
    if defconfig != null then "make $makeFlags ${hostFlagArg} ${defconfig}"
    else if eraName == "k2.6" then ''yes "" | make $makeFlags ${hostFlagArg} oldconfig''
    else "make $makeFlags ${hostFlagArg} olddefconfig";

  # gcc major of the resolved toolchain, for the k2.6 header-dispatch shim.
  gccMajor = lib.versions.major toolchain.gccVer;

in
stdenv.mkDerivation {
  pname = "linux-${arch}";
  inherit version src;

  nativeBuildInputs = [ toolchain ] ++ (with pkgs; [
    gnumake bc bison flex openssl.dev elfutils.dev perl cpio gawk
    rsync # modern kernels (>= 5.3) shell out to rsync in `headers_install`
  ]);

  patches = eraQuirks.patches;

  postPatch = ''
    # Kbuild helper scripts carry shebangs like `#!/usr/bin/awk -f` (e.g. 5.10's
    # scripts/ld-version.sh) that don't exist in the Nix sandbox; without this
    # they fail "not found" and cascade into Kconfig syntax errors.
    patchShebangs scripts tools 2>/dev/null || true
  ''
    + lib.optionalString (config != null) ''cp ${config} .config''
    + lib.optionalString (eraName == "k2.6") ''
    # 2.6.x ships only compiler-gcc{3,4}.h, but compiler-gcc.h does
    # `#include linux/compiler-gcc<__GNUC__>.h`, so a gcc >= 5 build dies on a
    # missing compiler-gcc<MAJOR>.h. Reuse the gcc4 definitions for newer gcc.
    # This is the upper-bound workaround that makes accepting gcc 5.3.0 viable
    # on the k2.6 band (pure header dispatch, no codegen change).
    if [ -f include/linux/compiler-gcc4.h ] && [ ! -f include/linux/compiler-gcc${gccMajor}.h ]; then
      cp include/linux/compiler-gcc4.h include/linux/compiler-gcc${gccMajor}.h
    fi

    # Modern host Perl (>= 5.22) removed `defined(@array)`; 2.6.x's
    # kernel/timeconst.pl still uses it and aborts the header-gen step.
    if [ -f kernel/timeconst.pl ]; then
      sed -i 's/defined(@\([A-Za-z_][A-Za-z0-9_]*\))/@\1/g' kernel/timeconst.pl
    fi

    # gcc >= 5 defaults to C99 (gnu11) inline semantics; 2.6.x assumes gnu89,
    # so plain `inline` funcs in headers (pin_inotify_watch, …) emit a duplicate
    # external definition per TU -> "multiple definition" at link. Restore gnu89
    # inline. (-fno-common is stable anchor text in old top-level Makefiles.)
    sed -i 's/-fno-common/-fno-common -fgnu89-inline/' Makefile

    # A gcc newer than this 2.6 tree (we use an era-appropriate 4.9.4, but even
    # that postdates 2.6.31 by years) raises warnings the tree predates — e.g.
    # -Wunused-but-set-variable (gcc >= 4.6). Several arch subdir Makefiles hard-
    # code -Werror, which lands AFTER our KCFLAGS=-Wno-error on the compile line
    # and therefore wins. Strip standalone -Werror tree-wide (the trailing
    # [[:space:]]/$ guard keeps -Werror-implicit-function-declaration and
    # -Werror=<x> intact). We build kernels, we don't lint them.
    find . \( -name Makefile -o -name Kbuild -o -name '*.mk' \) -print0 \
      | xargs -0 sed -i -E 's/-Werror([[:space:]]|$)/\1/g'
  '';

  makeFlags = [
    "ARCH=${kernelArch}"
    "CROSS_COMPILE=${crossPrefix}"
    "HOSTCC=${pkgs.stdenv.cc}/bin/cc"
  ] ++ eraQuirks.extraMake
    ++ lib.mapAttrsToList (k: v: "${k}=${v}") archMakeVars;

  buildPhase = ''
    runHook preBuild
    ${configCmd}
    make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES
    ${lib.optionalString buildModules "make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES modules"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    # vmlinux + the bits the rehosting flow consumes (kernel-devel for igloo_driver)
    cp vmlinux $out/ 2>/dev/null || true
    ${lib.optionalString buildModules ''
      make $makeFlags INSTALL_MOD_PATH=$out modules_install
    ''}
    make $makeFlags INSTALL_HDR_PATH=$out/kernel-devel headers_install
    runHook postInstall
  '';

  passthru = { inherit eraName toolchain; cross = crossPrefix; };
}
