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

  # Per-era build quirks (old trees fight modern host tools). Stub — grow this.
  eraQuirks = {
    "k2.6" = { patches = [ ]; extraMake = "KBUILD_NOPEDANTIC=1"; };
    "k3" = { patches = [ ]; extraMake = ""; };
    "k4" = { patches = [ ]; extraMake = ""; };
    "k6" = { patches = [ ]; extraMake = ""; };
  }.${eraName};

  # Config materialization. A board defconfig target generates .config wholesale
  # (works on every era). A supplied .config needs normalizing against the tree:
  # `olddefconfig` only exists from ~2.6.36, so fall back to piped `oldconfig`
  # on the k2.6 band.
  configCmd =
    if defconfig != null then "make $makeFlags ${defconfig}"
    else if eraName == "k2.6" then ''yes "" | make $makeFlags oldconfig''
    else "make $makeFlags olddefconfig";

  # gcc major of the resolved toolchain, for the k2.6 header-dispatch shim.
  gccMajor = lib.versions.major toolchain.gccVer;

in
stdenv.mkDerivation {
  pname = "linux-${arch}";
  inherit version src;

  nativeBuildInputs = [ toolchain ] ++ (with pkgs; [
    gnumake bc bison flex openssl.dev elfutils.dev perl cpio gawk
  ]);

  patches = eraQuirks.patches;

  postPatch = lib.optionalString (config != null) ''cp ${config} .config''
    + lib.optionalString (eraName == "k2.6") ''
    # 2.6.x ships only compiler-gcc{3,4}.h, but compiler-gcc.h does
    # `#include linux/compiler-gcc<__GNUC__>.h`, so a gcc >= 5 build dies on a
    # missing compiler-gcc<MAJOR>.h. Reuse the gcc4 definitions for newer gcc.
    # This is the upper-bound workaround that makes accepting gcc 5.3.0 viable
    # on the k2.6 band (pure header dispatch, no codegen change).
    if [ -f include/linux/compiler-gcc4.h ] && [ ! -f include/linux/compiler-gcc${gccMajor}.h ]; then
      cp include/linux/compiler-gcc4.h include/linux/compiler-gcc${gccMajor}.h
    fi
  '';

  makeFlags = [
    "ARCH=${kernelArch}"
    "CROSS_COMPILE=${crossPrefix}"
    "HOSTCC=${pkgs.stdenv.cc}/bin/cc"
  ] ++ lib.optional (eraQuirks.extraMake != "") eraQuirks.extraMake
    ++ lib.mapAttrsToList (k: v: "${k}=${v}") archMakeVars;

  buildPhase = ''
    runHook preBuild
    ${configCmd}
    make $makeFlags -j$NIX_BUILD_CORES
    ${lib.optionalString buildModules "make $makeFlags -j$NIX_BUILD_CORES modules"}
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
