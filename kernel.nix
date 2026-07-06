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
  # Strictness for the supplied-`config` path. Feeding a vendor/firmware .config
  # into a tree it wasn't written for is hazardous — new kernels add AND rename
  # symbols, so normalization silently drops the unknowns (kbuild docs: oldconfig
  # on an old .config "won't necessarily produce a working kernel"). We always LOG
  # the drift (listnewconfig + KCONFIG_WARN_UNKNOWN_SYMBOLS + a before/after diff);
  # `configStrict = true` additionally FAILS the build if the .config referenced
  # symbols unknown to this tree (the genuine red flag — renamed/dropped, not the
  # expected new-symbol gaps). Gate it per-target like nixpkgs' ignoreConfigErrors.
  configStrict ? false,
  # Kconfig symbols a cross / musl KERNEL-build toolchain fundamentally can't
  # satisfy — auto-disabled (with a logged notice) IF the materialized config
  # enables them, so "build any config" (e.g. allmodconfig) degrades gracefully
  # instead of dying. Neither is the kernel proper: GCC_PLUGINS are host .so's
  # loaded by the cross `cc1`, and a prebuilt cross gcc vs the host g++ are
  # different builds → the plugin fails to initialize; SAMPLES builds userspace
  # demo programs against the target libc, several of which assume glibc headers
  # (bits/wordsize.h, fsid_t.val) that musl doesn't provide. Clear/extend per
  # caller (e.g. `[]` on a glibc/host-matched toolchain that can do plugins).
  capabilityDisable ? [ "GCC_PLUGINS" "SAMPLES" ],
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
  normalizeCmd =
    if defconfig != null then "make $makeFlags ${hostFlagArg} ${defconfig}"
    else if eraName == "k2.6" then ''yes "" | make $makeFlags ${hostFlagArg} oldconfig''
    else "make $makeFlags ${hostFlagArg} olddefconfig";

  # A defconfig target is tree-native, so it just runs. A supplied full `.config`
  # (postPatch already copied it to .config) gets wrapped with cross-version
  # visibility: snapshot it, list the new-in-tree symbols it lacks (listnewconfig),
  # then normalize while capturing kconfig's unknown-symbol warnings to a file for
  # logging and the optional strict gate. The before/after diff runs later in
  # buildPhase (after configTuneCmd, so it reflects configEnable/Disable too).
  configCmd =
    if config == null then normalizeCmd
    else ''
      cp .config .config.ks-orig
      echo "=== kernelsmith config check: symbols new in ${version} that this .config lacks ==="
      make $makeFlags ${hostFlagArg} listnewconfig 2>/dev/null || echo "(listnewconfig unavailable on this tree)"
      ${normalizeCmd} 2> .config.ks-warn || { cat .config.ks-warn >&2; exit 1; }
      cat .config.ks-warn >&2   # surface unknown/renamed-symbol warnings to the build log
      ${lib.optionalString configStrict ''
        if grep -qi "unknown symbol" .config.ks-warn; then
          echo "kernelsmith: configStrict — supplied .config references symbols unknown to ${version} (renamed/dropped); see warnings above" >&2
          exit 1
        fi
      ''}
    '';

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

  # Capability guard: after the config is fully materialized, drop any symbol the
  # cross/musl kernel-build toolchain can't satisfy IF (and only if) it's enabled,
  # logging each. Runs last so it overrides defconfig + caller configEnable. This
  # is what lets `defconfig = "allmodconfig"` build — it enables GCC_PLUGINS and
  # SAMPLES, neither buildable here — without a config-specific carve-out.
  capabilityDisableCmd = lib.optionalString (capabilityDisable != [ ]) ''
    ks_dirty=
    for sym in ${lib.concatStringsSep " " capabilityDisable}; do
      if grep -q "^CONFIG_$sym=y" .config; then
        echo "kernelsmith: auto-disabling CONFIG_$sym — unsupported by the cross/musl kernel-build toolchain (capabilityDisable)" >&2
        ./scripts/config --disable "$sym"
        ks_dirty=1
      fi
    done
    if [ -n "$ks_dirty" ]; then ( set +o pipefail; yes "" | make $makeFlags ${hostFlagArg} oldconfig ); fi
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
    # Config-driven host tools. Inert unless a .config selects them, so they cost
    # nothing for minimal defconfigs but keep a rich firmware config from failing
    # (or silently degrading) on a tool the boot sweep's lean configs never hit:
    kmod #   `make modules_install` -> depmod; without it modules.dep/.alias/
    #        .symbols are never generated (non-fatal warning, incomplete tree).
    zstd lz4 lzop #  KERNEL_ZSTD/LZ4/LZO, RD_*, MODULE_COMPRESS_* (gzip/xz/bzip2
    #        already come via stdenv). zstd is the default compressor on some arches.
    pahole #  DEBUG_INFO_BTF (BPF): link-vmlinux.sh hard-errors without pahole.
    util-linux #  `hexdump`, used by arm64's EFI zboot stub (libstub/Makefile.zboot
    #        -> vmlinuz.efi) and various other arch boot-image steps.
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
    # Reproducible build metadata (research: nixpkgs build.nix + tuxmake). Fixed
    # identity + a timestamp derived from SOURCE_DATE_EPOCH (stdenv pins it) so
    # /proc/version and other embedded strings are deterministic across rebuilds.
    export KBUILD_BUILD_USER=kernelsmith
    export KBUILD_BUILD_HOST=kernelsmith
    export KBUILD_BUILD_VERSION=1-kernelsmith
    export KBUILD_BUILD_TIMESTAMP="$(date -u -d @''${SOURCE_DATE_EPOCH:-315532800})"
    # Make kconfig warn (not silently drop) on symbols the supplied .config sets
    # that this tree doesn't define — renamed/dropped across versions. Ignored by
    # pre-5.x kconfig, so harmless on the old bands.
    export KCONFIG_WARN_UNKNOWN_SYMBOLS=1
    ${configCmd}
    ${configTuneCmd}
    ${capabilityDisableCmd}
    ${lib.optionalString (config != null) ''
      echo "=== kernelsmith config check: .config changes after normalization (< supplied / > tree) ==="
      { diff .config.ks-orig .config || true; } | grep -E '^[<>].*CONFIG' | head -n 300 || echo "(no CONFIG-line changes)"
    ''}
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
