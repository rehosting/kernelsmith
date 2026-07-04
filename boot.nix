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
# Cells with NO usable qemu machine are omitted here (documented, not oversights):
#   - mips64eb : SGI IP27 (Origin) has no qemu machine; codegen proven via mips64el.
#   - powerpc64: qemu -M pseries emulates a modern PAPR LPAR whose in-kernel support
#                postdates 2.6.31 (SLOF can't hand off); codegen proven via powerpc.
#   - armhf    : k2.6 armhf targets OMAP3430, not in qemu; toolchain == armel's.
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
  kernels  = lib.mapAttrs' (n: v: { name = "k26-${n}"; value = v; }) kernels;
  runners  = lib.mapAttrs' (n: v: { name = "k26-${n}"; value = v; }) runners;

  # aggregate boot-test of every bootable cell (one derivation)
  all = farm "boot-all" tests;
  # just the bootable kernels
  kernels-all = farm "boot-kernels-all" kernels;
}
