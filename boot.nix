# Bootable-qemu sweep: for each system, build a kernel on a defconfig + fragments
# chosen to ACTUALLY BOOT on an available qemu machine, then run qemu headless in
# a sandboxed derivation and assert the boot got to userland/root-mount.
#
#   nix build -f boot.nix all --keep-going        # boot-test every cell
#   nix build -f boot.nix tests.k26-mipsel        # one cell's boot test
#   nix build -f boot.nix kernels.k26-armel        # just the bootable kernel
#   nix run   -f boot.nix runners.k26-mipsel       # interactive qemu (Ctrl-A x to quit)
#
# This is DISTINCT from validate-sweep.nix. That sweep picks endianness/width-
# definite boards (ip22/ip27/omap3430) that *build* but have no qemu machine, so
# they prove codegen, not boot. Here we pick the qemu-friendly target for the same
# silicon class — e.g. mipseb boots on a big-endian `malta` (malta_defconfig +
# CPU_BIG_ENDIAN=y) rather than the unbootable SGI Indy ip22. "Bootable" = the
# kernel reaches the point where it looks for / fails to find a root fs (we boot
# with no rootfs on purpose); that panic is the success marker.
#
# 8 of the 9 kernel-capable k2.6 arches boot here. The trick for the "hard" ones
# was picking the period-correct model qemu DOES emulate, not the endianness-
# definite board validate-sweep uses: mips64eb boots a 64-bit big-endian malta
# (not SGI IP27), armhf boots a Cortex-A8 realview-pb-a8 (not OMAP3430).
#
# ONE arch can't boot on ANY qemu ppc64 machine at 2.6.31 — and it's a FIRMWARE
# wall, not a board or toolchain gap (the kernel builds clean and its prom_init
# runs). `powerpc64Kernel` below still BUILDS the g5 (PowerMac G5, 970) kernel to
# prove that, but there's no boot test:
#   - mac99 + -cpu 970: OpenBIOS's OF `claim` can't satisfy the kernel's device-tree
#     flatten ("No memory for flatten_device_tree (no room)") — OpenBIOS ppc64 CI
#     support is too thin for a 2.6.31 G5 kernel.
#   - pseries: SLOF + the in-kernel PAPR platform postdate 2.6.31 (SLOF can't hand
#     off — stuck at the "0 >" Forth prompt).
# ppc64 codegen is cross-validated by powerpc (ppc32), which boots on the same gcc.
{ }:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  src = url: sha256: pkgs.fetchurl { inherit url sha256; };

  # Same 2.6.31 tarball as validate-sweep.nix (the period-gcc kernel band).
  k26 = {
    version = "2.6.31";
    src = src "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-2.6.31.tar.xz"
      "02p8kg2n2d6i9r1hkyd7mdbz92xiiz7jpb851bx71w90r8rxzl2a";
  };

  # A kernel that starts and then fails to find a root fs prints one of these.
  # (x86 triple-faults on panic; with -no-reboot qemu then exits. Others halt, so
  # the boot test relies on the timeout to stop qemu and greps the captured log.)
  rootMarker = "VFS: Cannot open root|VFS: Unable to mount root|Attempted to kill init|Kernel panic - not syncing|No filesystem could mount root";

  # The bootable cells. Per cell:
  #   defconfig     in-tree config target (qemu-friendly board, may differ from
  #                 validate-sweep's endianness-definite one).
  #   configEnable  Kconfig fragments applied over the defconfig (buildKernel).
  #   qemuSystem    qemu-system-<x> binary name (from pkgs.qemu).
  #   machine       -M value.
  #   cpu           -cpu value, or null for the machine default.
  #   mem           -m value.
  #   cmdline       kernel -append (console= routed to the machine's serial).
  #   extraArgs     any extra qemu args.
  # The image booted is the kernel's own passthru.bootImageFile (zImage for arm,
  # bzImage for x86, vmlinux elsewhere — MIPS/PPC boot the ELF directly).
  cells = {
    mipsel = {
      defconfig = "malta_defconfig";
      qemuSystem = "qemu-system-mipsel"; machine = "malta"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };
    mipseb = {
      # Endianness is a Kconfig `choice`: enabling BIG isn't enough, LITTLE must
      # be disabled or oldconfig keeps the little-endian default and the mips-linux
      # (BE) toolchain still emits an -EL image qemu-system-mips rejects.
      defconfig = "malta_defconfig";
      configEnable = [ "CPU_BIG_ENDIAN" ]; configDisable = [ "CPU_LITTLE_ENDIAN" ];
      qemuSystem = "qemu-system-mips"; machine = "malta"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };
    mips64el = {
      defconfig = "fulong_defconfig";   # pre-rename spelling of fuloong2e
      qemuSystem = "qemu-system-mips64el"; machine = "fuloong2e"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };
    armel = {
      defconfig = "versatile_defconfig";
      qemuSystem = "qemu-system-arm"; machine = "versatilepb"; cpu = null;
      mem = "128M"; cmdline = "console=ttyAMA0"; extraArgs = "";
    };
    powerpc = {
      # pmac32_defconfig ships SERIAL_PMACZILOG=m (a module — unavailable at boot)
      # and no console driver, so once 2.6.31 shuts off its early udbg console
      # ("turn off boot console udbg0") the machine goes silent (keep_bootcon
      # postdates 2.6.31). Build the escc serial + its console in; with
      # SERIAL_PMACZILOG_TTYS=y (defconfig default) the port is ttyS0. g3beige
      # (Heathrow PowerMac) wires escc ch-a to -nographic stdio; mac99 doesn't.
      defconfig = "pmac32_defconfig";
      configEnable = [ "SERIAL_PMACZILOG" "SERIAL_PMACZILOG_CONSOLE" ];
      qemuSystem = "qemu-system-ppc"; machine = "g3beige"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };
    x86_64 = {
      defconfig = "x86_64_defconfig";
      qemuSystem = "qemu-system-x86_64"; machine = "pc"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };

    # The three below were previously "omitted (no qemu machine)" — but that was a
    # BOARD choice, not a toolchain gap. Each has a period-correct model qemu DOES
    # emulate; we just weren't using it. The kernels always built; now they boot.

    # SGI IP27 (validate-sweep's endianness-definite ip27) has no qemu model, but a
    # 64-bit big-endian malta does (qemu-system-mips64 -M malta). Flip the 32-bit LE
    # malta_defconfig to 64-bit BE (both are Kconfig `choice`s → enable the wanted,
    # disable the default, or oldconfig keeps 32BIT/LE). Exercises the mips64 BE ABI
    # that mips64el only covers little-endian.
    mips64eb = {
      defconfig = "malta_defconfig";
      configEnable = [ "64BIT" "CPU_MIPS64_R1" "CPU_BIG_ENDIAN" ];
      configDisable = [ "32BIT" "CPU_MIPS32_R2" "CPU_LITTLE_ENDIAN" ];
      qemuSystem = "qemu-system-mips64"; machine = "malta"; cpu = null;
      mem = "256M"; cmdline = "console=ttyS0"; extraArgs = "";
    };

    # OMAP3430 (validate-sweep's omap_3430sdp) isn't in qemu, but the RealView
    # Platform Baseboard for Cortex-A8 is (-M realview-pb-a8) — a genuine ARMv7 core,
    # so this is the arch's first real hard-float-capable (ARMv7) kernel boot, vs
    # armel's ARMv5 versatilepb. realview_defconfig defaults to the V6 boards; switch
    # it to the A8 platform + V7 cpu. Boots the zImage (ARM virtual vmlinux entry).
    armhf = {
      # realview_defconfig is a MULTI-board kernel: the v6 boards (EB/PB11MP/PB1176)
      # keep CONFIG_CPU_V6 on, and arch/arm/Makefile assigns the v6 -march flag AFTER
      # the v7 one (`:=`, not `+=`, and v6's line follows v7's), so v6 wins and gas
      # rejects the ARMv7 `isb`/`dsb` in cache-v7.S. Reduce it to a PBA8-only (v7)
      # kernel: enable the A8 board + CPU_V7, drop the v6 boards so CPU_V6 deselects
      # and the v7 -march wins.
      defconfig = "realview_defconfig";
      configEnable = [ "MACH_REALVIEW_PBA8" "CPU_V7" ];
      configDisable = [ "MACH_REALVIEW_EB" "MACH_REALVIEW_PB11MP" "MACH_REALVIEW_PB1176" ];
      qemuSystem = "qemu-system-arm"; machine = "realview-pb-a8"; cpu = null;
      mem = "256M"; cmdline = "console=ttyAMA0"; extraArgs = "";
    };
  };

  # buildKernel for one cell — bootable image included via kernel.nix's bootImage.
  mkKernel = arch: c: flake.buildKernel {
    inherit (k26) version src;
    inherit arch;
    defconfig = c.defconfig;
    configEnable = c.configEnable or [ ];
    configDisable = c.configDisable or [ ];
    buildModules = false;   # boot smoke test: kernel image only
  };

  kernels = lib.mapAttrs mkKernel cells;

  # Build-only: the ppc64 PowerMac G5 (970) kernel. It compiles clean and its
  # prom_init runs, but no qemu ppc64 firmware boots a 2.6.31 ppc64 kernel (see the
  # header). g5_defconfig has SERIAL_PMACZILOG off entirely, so build the escc
  # console in (as ppc32 does). FTRACE stays off via kernel.nix's
  # kernelConfigDisable["k2.6-powerpc64"] (gcc 4.4 ppc64 ADDR16_HI trampoline).
  powerpc64Kernel = flake.buildKernel {
    inherit (k26) version src;
    arch = "powerpc64";
    defconfig = "g5_defconfig";
    configEnable = [ "SERIAL_PMACZILOG" "SERIAL_PMACZILOG_CONSOLE" ];
    buildModules = false;
  };

  cpuArg = c: lib.optionalString (c.cpu != null) "-cpu ${c.cpu}";

  # The qemu command (shared by the boot-test derivation and the interactive
  # runner). $KERNEL is the kernel store path; boots its own bootImageFile.
  qemuCmd = arch: c: kernel: ''
    ${c.qemuSystem} -M ${c.machine} ${cpuArg c} -m ${c.mem} \
      -kernel ${kernel}/${kernel.bootImageFile} \
      -append '${c.cmdline}' \
      -nographic -no-reboot ${c.extraArgs}'';

  # A boot-test derivation: run qemu headless with a timeout, grep the log for the
  # root-mount marker. Timeout is expected to fire on arches that halt on panic
  # (x86 exits via -no-reboot); either way success is decided by the grep.
  mkBootTest = arch: c:
    let kernel = kernels.${arch}; in
    pkgs.runCommand "boot-k26-${arch}"
      { nativeBuildInputs = [ pkgs.qemu ]; }
      ''
        echo "=== booting k2.6 ${arch} on ${c.qemuSystem} -M ${c.machine} ==="
        set +e
        timeout 180 ${qemuCmd arch c kernel} > boot.log 2>&1
        set -e
        echo "--- boot.log (last 60 lines) ---"
        tail -n 60 boot.log || true
        echo "---------------------------------"
        if grep -Eq '${rootMarker}' boot.log; then
          echo "BOOT OK (${arch}): reached root-fs stage"
          mkdir -p $out
          cp boot.log $out/boot.log
          grep -Eo 'Linux version [^ ]+ .*' boot.log | head -1 > $out/banner || true
        else
          echo "BOOT FAILED (${arch}): root-fs marker not found" >&2
          exit 1
        fi
      '';

  tests = lib.mapAttrs mkBootTest cells;

  # Interactive runner: `nix run -f boot.nix runners.k26-mipsel`.
  mkRunner = arch: c:
    pkgs.writeShellScriptBin "boot-k26-${arch}" ''
      export PATH=${pkgs.qemu}/bin:$PATH
      echo "booting k2.6 ${arch} (${c.machine}); quit with Ctrl-A x" >&2
      exec ${qemuCmd arch c kernels.${arch}}
    '';

  runners = lib.mapAttrs mkRunner cells;

  farm = name: set: pkgs.linkFarm name
    (lib.mapAttrsToList (n: v: { name = "k26-${n}"; path = v; }) set);
in
{
  # namespaced so `nix build -f boot.nix tests.k26-mipsel` etc. work
  tests    = lib.mapAttrs' (n: v: { name = "k26-${n}"; value = v; }) tests;
  # kernels includes the build-only ppc64 G5 (no boot test — firmware-blocked)
  kernels  = (lib.mapAttrs' (n: v: { name = "k26-${n}"; value = v; }) kernels)
             // { k26-powerpc64 = powerpc64Kernel; };
  runners  = lib.mapAttrs' (n: v: { name = "k26-${n}"; value = v; }) runners;

  # aggregate boot-test of every bootable cell (one derivation): 8/9 arches
  all = farm "boot-all" tests;
  # every bootable kernel + the build-only ppc64 G5
  kernels-all = farm "boot-kernels-all" (kernels // { powerpc64 = powerpc64Kernel; });
}
