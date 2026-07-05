# buildKernel: the unified entrypoint. Give it (version, arch, src, config) and
# it self-selects the right cross toolchain from the matrix via resolve.nix.
#
# This is the "move between kernel versions as targets" piece: the toolchain is
# a *derived* input, not something the caller wires up. Layer 2 over the
# toolchain matrix. The actual kernel-build quirk handling (per-era patches,
# HOSTCC fixups) lives in `eraQuirks` — stubbed here; this is where the inherent
# old-kernel pain accretes as you widen the version range.
{ pkgs, resolve, resolveToolchain }:

{
  version, # e.g. "3.18.140"
  arch, # matrix arch key, e.g. "mipsel"
  src, # kernel source (fetchurl/fetchgit)
  config ? null, # a full .config file (mutually exclusive with defconfig)
  defconfig ? null, # an in-tree config make-target, e.g. "versatile_defconfig"
  archMakeVars ? { }, # ARCH= / CROSS_COMPILE handled below; extra make vars here
  buildModules ? true,
  # Override the per-arch bootable image with `{ target; file; }` (make-target +
  # path under the build tree). Needed for powerpc pseries, whose bootable form is
  # a per-platform bootwrapper (`make zImage` → arch/powerpc/boot/zImage.pseries)
  # that SLOF loads correctly, unlike the raw vmlinux ELF entry. null = arch default.
  bootImageOverride ? null,
  # Caller-supplied Kconfig fragments applied AFTER the defconfig/.config is
  # materialized (scripts/config --enable/--disable, then re-resolved). Distinct
  # from the internal per-(era,arch) `kernelConfigDisable` below (which is about
  # toolchain link limits); these are for board/boot tailoring — e.g. a bootable
  # big-endian malta kernel is malta_defconfig + configEnable ["CPU_BIG_ENDIAN"].
  configEnable ? [ ],
  configDisable ? [ ],
  # Device-tree blob basenames to install to $out/dtbs/<name> (e.g.
  # "versatile-pb.dtb"). When non-empty we run the `dtbs` make target (builds the
  # scripts/dtc host tool + every board DTB, version-agnostic — 6.5+ moved ARM DTS
  # into vendor subdirs, and a bare `make foo.dtb` target won't build dtc first) and
  # copy the named ones out by basename. Modern DT-only ARM boards (versatile,
  # vexpress, …) need one passed to qemu via -dtb; qemu's `virt` synthesizes its own.
  dtbs ? [ ],
}:
assert (config != null) != (defconfig != null) ||
  throw "buildKernel: pass exactly one of `config` or `defconfig`";

let
  inherit (pkgs) lib stdenv;

  eraName = resolve.eraFor version;
  # The toolchain is resolved by the shared `resolveToolchain` (flake.nix) — the
  # single source of truth, so an ad-hoc `toolchainFor`/`kbuild` invocation and a
  # buildKernel here always agree on compiler AND ABI. It prefers a period-correct
  # KERNEL-only toolchain (the whole k2.6 band, plus k3-powerpc64: an ELFv1-default
  # gcc 6.5.0 for the BE pseries build the elfv2-default Bootlin gcc can't produce)
  # and falls back to the vendored/musl era toolchain otherwise.
  toolchain = resolveToolchain version arch;

  # mcm target triple -> kernel CROSS_COMPILE prefix
  crossPrefix = "${toolchain.target}-";

  # -Wno-error compiler shim. Wraps the CROSS gcc and the HOST cc so every
  # invocation gets `-Wno-error` appended LAST — defeating `-Werror` no matter
  # where the tree injects it (top Makefile, arch/subdir Makefile, or tools/),
  # because a trailing flag wins. This is one lever replacing three fragile knobs:
  # `KCFLAGS=-Wno-error` (which a subdir `-Werror` appended *after* it defeats),
  # the tree-wide `-Werror` strip sed, and the `-Wno-error` inside HOSTCFLAGS
  # (whose OVERRIDE-vs-APPEND semantics flip at 4.19). Real flags (e.g. -fcommon
  # for old host dtc) stay in HOSTCFLAGS. The shim only shadows the compiler; ld/
  # as/objcopy resolve to the real toolchain (later on PATH). We build kernels, we
  # don't lint them — demoting -Werror is always safe here, for any era/gcc.
  ccShim = pkgs.runCommand "kernelsmith-ccshim-${arch}" { } ''
    mkdir -p $out/bin
    for n in gcc cc g++ c++; do
      if [ -x ${toolchain}/bin/${crossPrefix}$n ]; then
        { echo '#!${pkgs.runtimeShell}'
          echo 'exec ${toolchain}/bin/${crossPrefix}'"$n"' "$@" -Wno-error'
        } > $out/bin/${crossPrefix}$n
        chmod +x $out/bin/${crossPrefix}$n
      fi
    done
    { echo '#!${pkgs.runtimeShell}'
      echo 'exec ${pkgs.stdenv.cc}/bin/cc "$@" -Wno-error'
    } > $out/bin/kernelsmith-hostcc
    chmod +x $out/bin/kernelsmith-hostcc
  '';

  # matrix arch key -> kernel ARCH= value
  kernelArch = {
    armel = "arm"; armhf = "arm"; arm64 = "arm64";
    mipseb = "mips"; mipsel = "mips"; mips64eb = "mips"; mips64el = "mips";
    powerpc = "powerpc"; powerpcle = "powerpc";
    powerpc64 = "powerpc"; powerpc64le = "powerpc";
    x86_64 = "x86_64";
  }.${arch} or (throw "buildKernel: no kernel ARCH mapping for ${arch}");

  # Per-arch bootable image, in addition to the raw `vmlinux`. Some arches don't
  # boot from the ELF `vmlinux` under a bootloader/qemu: ARM's vmlinux entry is a
  # *virtual* address (0xc0008000) that's meaningless before the MMU is on, and x86
  # needs the real-mode `bzImage` setup header. So build+install the decompressed
  # boot image those arches actually boot. MIPS boots `vmlinux` directly (KSEG0
  # maps without the MMU) and powerpc's zImage needs a per-platform bootwrapper, so
  # both stay vmlinux-only here. `{ target; file; }`, or null to skip.
  bootImage = if bootImageOverride != null then bootImageOverride else {
    arm = { target = "zImage"; file = "arch/arm/boot/zImage"; };
    arm64 = { target = "Image.gz"; file = "arch/arm64/boot/Image.gz"; };
    x86_64 = { target = "bzImage"; file = "arch/x86/boot/bzImage"; };
  }.${kernelArch} or null;

  # Per-era build quirks (old trees fight modern host + cross tools). The whole
  # `-Werror` axis is now handled by `ccShim` above (trailing -Wno-error on both
  # cross + host compiles), so it's gone from here. What remains is the ONE real
  # host-flag quirk the shim can't express: -fcommon. gcc>=10 defaults to
  # -fno-common, which breaks old host tools' tentative definitions (dtc's
  # `yylloc`); k3's 3.18 dtc needs it. Because pre-4.19 `HOSTCFLAGS` OVERRIDES the
  # tree's host flags (>=4.19 it appends), k3 must restate the 3.18 defaults
  # alongside -fcommon. `hostCFlags` is threaded in as a single quoted
  # `HOSTCFLAGS=...` token (it can contain spaces, which would word-split the
  # unquoted $makeFlags expansion).
  eraQuirks = {
    "k2.6" = { patches = [ ]; extraMake = [ "KBUILD_NOPEDANTIC=1" ]; hostCFlags = ""; };
    "k3" = { patches = [ ]; extraMake = [ ];
      hostCFlags = "-Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu89 -fcommon"; };
    "k4" = { patches = [ ]; extraMake = [ ]; hostCFlags = ""; };
    "k6" = { patches = [ ]; extraMake = [ ]; hostCFlags = ""; };
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

  # Per-(era,arch) Kconfig symbols to force-disable after materializing the
  # config. Rare, surgical: for cells where an *optional* kernel feature emits
  # code the period toolchain can't link, and the feature is irrelevant to
  # rehosting. Currently just ppc64 k2.6: the function-graph tracer's return
  # trampoline references `ftrace_return_to_handler` via a 32-bit `lis/addi`
  # (R_PPC64_ADDR16_HI) that overflows at the 64-bit kernel link address — gcc 4.4
  # predates the medium code model that would use the TOC. Dropping FTRACE (a
  # debug/profiling feature) is the only ADDR16_HI site in pseries_defconfig, so
  # the kernel then links clean. (ppc64_defconfig additionally drags in the legacy
  # iSeries platform, which has its own ADDR16_HI site — use pseries_defconfig.)
  kernelConfigDisable = {
    "k2.6-powerpc64" = [ "FTRACE" "FUNCTION_TRACER" "FUNCTION_GRAPH_TRACER" ];
  }."${eraName}-${arch}" or [ ];

  # Full disable set = internal toolchain-driven + caller board/boot fragments.
  allDisable = kernelConfigDisable ++ configDisable;

  # scripts/config --enable/--disable each, then re-resolve (pipefail-safe: `yes`
  # gets SIGPIPE when oldconfig closes the pipe).
  configTuneCmd = lib.optionalString (allDisable != [ ] || configEnable != [ ]) ''
    ./scripts/config ${lib.concatMapStringsSep " " (c: "--enable ${c}") configEnable} \
      ${lib.concatMapStringsSep " " (c: "--disable ${c}") allDisable}
    ( set +o pipefail; yes "" | make $makeFlags ${hostFlagArg} oldconfig )
  '';

  # gcc major of the resolved toolchain, for the k2.6 header-dispatch shim.
  gccMajor = lib.versions.major toolchain.gccVer;

in
stdenv.mkDerivation {
  pname = "linux-${arch}";
  inherit version src;

  # ccShim FIRST so its -Wno-error gcc/cc wrappers shadow the real toolchain's
  # (ld/as/etc. fall through to `toolchain`, later on PATH).
  nativeBuildInputs = [ ccShim toolchain ] ++ (with pkgs; [
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

    # A gcc that isn't the exact one this 2.6 tree was tuned for defaults to C99
    # (gnu11) inline semantics; 2.6.x assumes gnu89, so plain `inline` funcs in
    # headers (pin_inotify_watch, …) emit a duplicate external definition per TU
    # -> "multiple definition" at link. Restore gnu89 inline. (No-op for the
    # period gcc 4.4 kernel band, which is gnu89 by default; still needed for the
    # musl gcc 4.9.4 fallback arches. -fno-common is stable anchor text in old
    # top-level Makefiles.) Tree-wide -Werror stripping is gone — `ccShim` handles
    # -Werror uniformly via a trailing -Wno-error on every compile.
    sed -i 's/-fno-common/-fno-common -fgnu89-inline/' Makefile
  '';

  makeFlags = [
    "ARCH=${kernelArch}"
    "CROSS_COMPILE=${crossPrefix}"
    "HOSTCC=${ccShim}/bin/kernelsmith-hostcc"
  ] ++ eraQuirks.extraMake
    ++ lib.mapAttrsToList (k: v: "${k}=${v}") archMakeVars;

  buildPhase = ''
    runHook preBuild
    ${configCmd}
    ${configTuneCmd}
    make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES
    ${lib.optionalString (bootImage != null)
      "make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES ${bootImage.target}"}
    ${lib.optionalString (dtbs != [ ])
      "make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES dtbs"}
    ${lib.optionalString buildModules "make $makeFlags ${hostFlagArg} -j$NIX_BUILD_CORES modules"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    # vmlinux + the bits the rehosting flow consumes (kernel-devel for igloo_driver)
    cp vmlinux $out/ 2>/dev/null || true
    # the arch's bootable image (zImage/bzImage/Image.gz), where it differs from vmlinux
    ${lib.optionalString (bootImage != null) ''
      cp ${bootImage.file} $out/ || { echo "boot image ${bootImage.file} missing" >&2; exit 1; }
    ''}
    ${lib.optionalString (dtbs != [ ]) ''
      mkdir -p $out/dtbs
      for d in ${lib.concatStringsSep " " dtbs}; do
        find arch/${kernelArch}/boot/dts -name "$d" -exec cp {} $out/dtbs/ \; \
          || { echo "dtb $d not found" >&2; exit 1; }
      done
    ''}
    ${lib.optionalString buildModules ''
      make $makeFlags INSTALL_MOD_PATH=$out modules_install
    ''}
    make $makeFlags INSTALL_HDR_PATH=$out/kernel-devel headers_install
    runHook postInstall
  '';

  passthru = { inherit eraName toolchain; cross = crossPrefix; bootImageFile = if bootImage != null then baseNameOf bootImage.file else "vmlinux"; };
}
