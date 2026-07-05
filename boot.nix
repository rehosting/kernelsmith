# Bootable-qemu sweep across ERAS: for each (band, arch) build a kernel on a
# defconfig + fragments chosen to ACTUALLY BOOT on an available qemu machine, then
# run qemu headless in a sandboxed derivation and assert the boot reached the
# root-fs stage (no rootfs supplied → a VFS/panic marker is success).
#
#   nix build -f boot.nix all --keep-going       # boot-test every cell, all bands
#   nix build -f boot.nix k4  --keep-going        # one band
#   nix build -f boot.nix tests.k4-powerpc64      # one cell's boot test
#   nix build -f boot.nix kernels.k26-armel       # just the bootable kernel
#   nix run   -f boot.nix runners.k4-arm64        # interactive qemu (Ctrl-A x)
#
# DISTINCT from validate-sweep.nix: that picks endianness/width-*definite* boards
# (ip22/ip27/omap3430) that build but have no qemu machine — it proves codegen.
# This picks the qemu-friendly model for the same silicon class and proves BOOT.
#
# The bands mirror validate-sweep's kernel versions. A cell may set `buildOnly` to
# be built (proving the toolchain) without a boot test — used where qemu firmware,
# not the kernel, is the blocker (k2.6 ppc64: see that cell).
{ }:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  src = url: sha256: pkgs.fetchurl { inherit url sha256; };

  # Per-band kernel tarballs (same versions as validate-sweep.nix).
  bands = {
    "k2.6" = { version = "2.6.31";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-2.6.31.tar.xz"
        "02p8kg2n2d6i9r1hkyd7mdbz92xiiz7jpb851bx71w90r8rxzl2a"; };
    "k3" = { version = "3.18.140";   # last 3.18.y; predates objtool (no thunk_64 issue)
      src = src "https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.140.tar.xz"
        "sha256-GMOJAcUTc4U0NdNkQiwZMe0FILFsxK6UQNeyCVvc4uA="; };
    # 5.10.229 (latest 5.10 stable), NOT 5.10.0: the Bootlin k4 toolchain ships
    # binutils 2.36, which omits the symbol table from empty objects (e.g. an
    # x86_64_defconfig thunk_64.o — no PREEMPTION/IRQ-tracing thunks), and 5.10.0's
    # objtool hard-errors "missing symbol table" on that. Later 5.10.y objtool
    # tolerates it. A real era-compat constraint: binutils 2.36 needs objtool >= 5.10.5.
    "k4" = { version = "5.10.229";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.229.tar.xz"
        "1q6di05rk4bsy91r03zw6vz14zzcpvv25dv7gw0yz1gzpgkbb9h8"; };
    "k6" = { version = "6.6";        # 6.6 objtool already tolerates empty objects
      src = src "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz"
        "sha256-2SagbGPdisffP4buH/ws4qO4Gi0WhITna1s4mrqOVtA="; };
  };

  # "k2.6" -> "k26" for attr/derivation-name friendliness.
  bandKey = b: lib.replaceStrings [ "." ] [ "" ] b;

  # A kernel that starts and then fails to find a root fs prints one of these.
  rootMarker = "VFS: Cannot open root|VFS: Unable to mount root|Attempted to kill init|Kernel panic - not syncing|No filesystem could mount root|Requested init";

  # band -> arch -> cell spec. Fields (all but defconfig/qemuSystem/machine/cmdline
  # optional): defconfig, configEnable[], configDisable[], qemuSystem, machine, cpu,
  # mem (default 256M), cmdline (console=…), extraArgs, buildOnly.
  bootTable = {
    # ---- k2.6 (period gcc 4.4.7, 2.6.31): 8/9 boot; ppc64 firmware-blocked ----
    "k2.6" = {
      mipsel = {
        defconfig = "malta_defconfig";
        qemuSystem = "qemu-system-mipsel"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mipseb = {
        # Endianness is a Kconfig `choice`: enabling BIG isn't enough, LITTLE must be
        # disabled or oldconfig keeps LE and the mips-linux (BE) toolchain emits an
        # -EL image qemu-system-mips rejects.
        defconfig = "malta_defconfig";
        configEnable = [ "CPU_BIG_ENDIAN" ]; configDisable = [ "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mips64el = {
        defconfig = "fulong_defconfig";   # pre-rename spelling of fuloong2e
        qemuSystem = "qemu-system-mips64el"; machine = "fuloong2e"; cmdline = "console=ttyS0";
      };
      # SGI IP27 (validate-sweep's ip27) has no qemu model; a 64-bit BE malta does.
      # Flip 32-bit LE malta_defconfig to 64-bit BE (both are Kconfig choices).
      mips64eb = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R1" "CPU_BIG_ENDIAN" ];
        configDisable = [ "32BIT" "CPU_MIPS32_R2" "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips64"; machine = "malta"; cmdline = "console=ttyS0";
      };
      armel = {
        defconfig = "versatile_defconfig";
        qemuSystem = "qemu-system-arm"; machine = "versatilepb"; mem = "128M";
        cmdline = "console=ttyAMA0";
      };
      # OMAP3430 (validate-sweep's omap_3430sdp) isn't in qemu; realview-pb-a8
      # (Cortex-A8, ARMv7) is — the arch's first real ARMv7 boot vs armel's ARMv5.
      # realview_defconfig is multi-board; the v6 boards keep CPU_V6 on and
      # arch/arm/Makefile lets the v6 -march (assigned after v7) win, so gas rejects
      # the ARMv7 isb/dsb in cache-v7.S. Reduce it to a PBA8-only (v7) kernel. Also
      # needs the armv7-a k2.6 toolchain (matrix.nix armhf --with-arch=armv7-a).
      armhf = {
        defconfig = "realview_defconfig";
        configEnable = [ "MACH_REALVIEW_PBA8" "CPU_V7" ];
        configDisable = [ "MACH_REALVIEW_EB" "MACH_REALVIEW_PB11MP" "MACH_REALVIEW_PB1176" ];
        qemuSystem = "qemu-system-arm"; machine = "realview-pb-a8"; cmdline = "console=ttyAMA0";
      };
      powerpc = {
        # pmac32_defconfig has SERIAL_PMACZILOG=m (module, unavailable at boot) + no
        # console driver, so 2.6.31 goes silent at "turn off boot console udbg0"
        # (keep_bootcon postdates 2.6.31). Build the escc console in; g3beige wires
        # escc ch-a to -nographic stdio (mac99 doesn't).
        defconfig = "pmac32_defconfig";
        configEnable = [ "SERIAL_PMACZILOG" "SERIAL_PMACZILOG_CONSOLE" ];
        qemuSystem = "qemu-system-ppc"; machine = "g3beige"; cmdline = "console=ttyS0";
      };
      x86_64 = {
        defconfig = "x86_64_defconfig";
        qemuSystem = "qemu-system-x86_64"; machine = "pc"; cmdline = "console=ttyS0";
      };
      # FIRMWARE-blocked, not a board/toolchain gap: PowerMac G5 (970) g5_defconfig
      # compiles clean and prom_init runs, but mac99/OpenBIOS can't OF-claim memory
      # for the DT flatten and pseries/SLOF postdates 2.6.31. Build-only; codegen
      # cross-validated by powerpc (ppc32, same gcc 4.4.7, boots). The modern bands
      # DO boot ppc64 (pseries), which is the point of proving other eras.
      powerpc64 = {
        defconfig = "g5_defconfig"; buildOnly = true;
        configEnable = [ "SERIAL_PMACZILOG" "SERIAL_PMACZILOG_CONSOLE" ];
        qemuSystem = "qemu-system-ppc64"; machine = "mac99"; cpu = "970fx"; cmdline = "console=ttyS0";
      };
    };

    # ---- k4 (gcc 9.x, 5.10): the modern band. More qemu machines, so the k2.6
    # gaps clear — ppc64/ppc64le boot on pseries, arm/arm64 on the DT-driven virt. --
    "k4" = {
      x86_64 = {
        defconfig = "x86_64_defconfig";
        qemuSystem = "qemu-system-x86_64"; machine = "pc"; cmdline = "console=ttyS0";
      };
      # Modern versatile is DT-only and qemu's versatilepb passes no DTB, so the
      # decompressor bails ("unrecognized machine ID … check your bootloader").
      # Build + pass versatile-pb.dtb.
      armel = {
        defconfig = "versatile_defconfig"; dtb = "versatile-pb.dtb";
        qemuSystem = "qemu-system-arm"; machine = "versatilepb"; mem = "128M";
        cmdline = "console=ttyAMA0";
      };
      # Modern ARM is DT-driven: multi_v7 + qemu's auto-generated `virt` DT is the
      # robust path (no per-board defconfig/DTB juggling). Drop GCC_PLUGINS:
      # multi_v7_defconfig turns on the ARM ssp-per-task gcc plugin, which is built
      # against a different gcc than the Bootlin cross compiler and won't load
      # ("incompatible gcc/plugin versions").
      armhf = {
        defconfig = "multi_v7_defconfig";
        configDisable = [ "GCC_PLUGINS" ];
        qemuSystem = "qemu-system-arm"; machine = "virt"; cmdline = "console=ttyAMA0";
      };
      arm64 = {
        defconfig = "defconfig";
        qemuSystem = "qemu-system-aarch64"; machine = "virt"; cpu = "cortex-a53";
        cmdline = "console=ttyAMA0";
      };
      mipsel = {
        defconfig = "malta_defconfig";
        qemuSystem = "qemu-system-mipsel"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mipseb = {
        defconfig = "malta_defconfig";
        configEnable = [ "CPU_BIG_ENDIAN" ]; configDisable = [ "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips"; machine = "malta"; cmdline = "console=ttyS0";
      };
      # 64-bit malta (uniform LE/BE, avoids the aging fuloong2e model). qemu's
      # default malta CPU is 32-bit, so a 64-bit kernel silently never starts —
      # pin a 64-bit core with -cpu MIPS64R2-generic.
      mips64el = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" ];
        configDisable = [ "32BIT" "CPU_MIPS32_R2" ];
        qemuSystem = "qemu-system-mips64el"; machine = "malta"; cpu = "MIPS64R2-generic";
        cmdline = "console=ttyS0";
      };
      mips64eb = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" "CPU_BIG_ENDIAN" ];
        configDisable = [ "32BIT" "CPU_MIPS32_R2" "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips64"; machine = "malta"; cpu = "MIPS64R2-generic";
        cmdline = "console=ttyS0";
      };
      powerpc = {
        defconfig = "pmac32_defconfig";
        qemuSystem = "qemu-system-ppc"; machine = "g3beige"; cmdline = "console=ttyS0";
      };
      # The k2.6 gap, cleared: modern pseries (SLOF + in-kernel PAPR) boots ppc64.
      powerpc64 = {
        defconfig = "pseries_defconfig";
        qemuSystem = "qemu-system-ppc64"; machine = "pseries"; mem = "1G";
        cmdline = "console=hvc0";
      };
      powerpc64le = {
        # LE pseries: pseries_defconfig + flip to little-endian. Drop COMPAT: the
        # LE flip turns on 32-bit compat, whose vdso32 needs `-m32` the pure-64-bit
        # LE Bootlin toolchain lacks ("-m32 not supported in this configuration").
        defconfig = "pseries_defconfig";
        configEnable = [ "CPU_LITTLE_ENDIAN" ];
        configDisable = [ "CPU_BIG_ENDIAN" "COMPAT" ];
        qemuSystem = "qemu-system-ppc64"; machine = "pseries"; mem = "1G";
        cmdline = "console=hvc0";
      };
    };

    # ---- k3 (gcc ~6.x, 3.18.140): predates the kernel gcc-plugins + objtool, so
    # x86_64/armhf need none of k4's plugin/objtool workarounds. ----
    "k3" = {
      x86_64 = {
        defconfig = "x86_64_defconfig";
        qemuSystem = "qemu-system-x86_64"; machine = "pc"; cmdline = "console=ttyS0";
      };
      # 3.18 versatile_defconfig is an ATAG (non-DT) kernel — no DTB needed (and
      # `make dtbs` builds none). k4/k6 versatile is DT-only and DOES need one.
      armel = {
        defconfig = "versatile_defconfig";
        qemuSystem = "qemu-system-arm"; machine = "versatilepb"; mem = "128M";
        cmdline = "console=ttyAMA0";
      };
      armhf = {
        defconfig = "multi_v7_defconfig";
        qemuSystem = "qemu-system-arm"; machine = "virt"; cmdline = "console=ttyAMA0";
      };
      arm64 = {
        defconfig = "defconfig";
        qemuSystem = "qemu-system-aarch64"; machine = "virt"; cpu = "cortex-a53";
        cmdline = "console=ttyAMA0";
      };
      mipsel = {
        defconfig = "malta_defconfig";
        qemuSystem = "qemu-system-mipsel"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mipseb = {
        defconfig = "malta_defconfig";
        configEnable = [ "CPU_BIG_ENDIAN" ]; configDisable = [ "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips"; machine = "malta"; cmdline = "console=ttyS0";
      };
      # 3.18's mips64 malta stays silent on -cpu MIPS64R2-generic (some CP0 feature
      # its setup trips on); a real 5K-family Malta core (5KEc) boots it.
      mips64el = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" ]; configDisable = [ "32BIT" "CPU_MIPS32_R2" ];
        qemuSystem = "qemu-system-mips64el"; machine = "malta"; cpu = "5KEc";
        cmdline = "console=ttyS0";
      };
      mips64eb = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" "CPU_BIG_ENDIAN" ];
        configDisable = [ "32BIT" "CPU_MIPS32_R2" "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips64"; machine = "malta"; cpu = "5KEc";
        cmdline = "console=ttyS0";
      };
      powerpc = {
        # 3.18 pmac32 (like 2.6.31) disables its early console and has no built-in
        # escc console → silent after "bootconsole [udbg0] disabled". Build it in.
        defconfig = "pmac32_defconfig";
        configEnable = [ "SERIAL_PMACZILOG" "SERIAL_PMACZILOG_CONSOLE" ];
        qemuSystem = "qemu-system-ppc"; machine = "g3beige"; cmdline = "console=ttyS0";
      };
      # The k3 ppc64 gap, CLEARED. Earlier this was build-only: the Bootlin buildroot
      # gcc defaults to ELFv2, so 3.18's BE Makefile (which emits -mcall-aixdesc and
      # assumes an ELFv1-default compiler) either wouldn't build or, with a forced
      # KCFLAGS=-mabi=elfv1, produced a mixed-ABI vmlinux SLOF trapped on. buildKernel
      # now routes k3 powerpc64 to a dedicated ELFv1-default kernel gcc 6.5.0
      # (matrix.k3PpcKernel; see kernel.nix), which builds clean and boots on
      # `-M pseries -cpu POWER8` — the documented BE recipe, matched against a
      # known-good Debian 3.16 reference. No ABI forcing.
      powerpc64 = {
        defconfig = "pseries_defconfig";
        qemuSystem = "qemu-system-ppc64"; machine = "pseries"; cpu = "POWER8"; mem = "1G";
        cmdline = "console=hvc0";
      };
      # NOTE: k3 powerpc64le is a documented gap. 3.18 always builds the 32-bit
      # vdso32, whose Makefile passes `-mlittle-endian` — a flag the Bootlin ppc64le
      # gcc doesn't recognize (it wants -mlittle) — and 3.18 has no COMPAT/VDSO32
      # knob to drop it. A 3.18-era-toolchain mismatch specific to ppc64le; the arch
      # boots fine on k4 and k6.
    };

    # ---- k6 (gcc 13.x, 6.6): same modern shape as k4 (plugin/vdso32/mips64-cpu
    # workarounds); 6.6 objtool already tolerates empty objects, so no .y pin. ----
    "k6" = {
      x86_64 = {
        defconfig = "x86_64_defconfig";
        qemuSystem = "qemu-system-x86_64"; machine = "pc"; cmdline = "console=ttyS0";
      };
      armel = {
        defconfig = "versatile_defconfig"; dtb = "versatile-pb.dtb";
        qemuSystem = "qemu-system-arm"; machine = "versatilepb"; mem = "128M";
        cmdline = "console=ttyAMA0";
      };
      armhf = {
        defconfig = "multi_v7_defconfig"; configDisable = [ "GCC_PLUGINS" ];
        qemuSystem = "qemu-system-arm"; machine = "virt"; cmdline = "console=ttyAMA0";
      };
      arm64 = {
        defconfig = "defconfig";
        qemuSystem = "qemu-system-aarch64"; machine = "virt"; cpu = "cortex-a53";
        cmdline = "console=ttyAMA0";
      };
      mipsel = {
        defconfig = "malta_defconfig";
        qemuSystem = "qemu-system-mipsel"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mipseb = {
        defconfig = "malta_defconfig";
        configEnable = [ "CPU_BIG_ENDIAN" ]; configDisable = [ "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips"; machine = "malta"; cmdline = "console=ttyS0";
      };
      mips64el = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" ]; configDisable = [ "32BIT" "CPU_MIPS32_R2" ];
        qemuSystem = "qemu-system-mips64el"; machine = "malta"; cpu = "MIPS64R2-generic";
        cmdline = "console=ttyS0";
      };
      mips64eb = {
        defconfig = "malta_defconfig";
        configEnable = [ "64BIT" "CPU_MIPS64_R2" "CPU_BIG_ENDIAN" ];
        configDisable = [ "32BIT" "CPU_MIPS32_R2" "CPU_LITTLE_ENDIAN" ];
        qemuSystem = "qemu-system-mips64"; machine = "malta"; cpu = "MIPS64R2-generic";
        cmdline = "console=ttyS0";
      };
      powerpc = {
        defconfig = "pmac32_defconfig";
        qemuSystem = "qemu-system-ppc"; machine = "g3beige"; cmdline = "console=ttyS0";
      };
      powerpc64 = {
        defconfig = "pseries_defconfig";
        qemuSystem = "qemu-system-ppc64"; machine = "pseries"; mem = "1G";
        cmdline = "console=hvc0";
      };
      powerpc64le = {
        # 6.6 dropped pseries_le_defconfig; flip pseries_defconfig to LE + drop COMPAT.
        defconfig = "pseries_defconfig";
        configEnable = [ "CPU_LITTLE_ENDIAN" ];
        configDisable = [ "CPU_BIG_ENDIAN" "COMPAT" ];
        qemuSystem = "qemu-system-ppc64"; machine = "pseries"; mem = "1G";
        cmdline = "console=hvc0";
      };
    };
  };

  # ---- machinery ----

  defMem = "256M";
  cpuArg = c: lib.optionalString (c ? cpu && c.cpu != null) "-cpu ${c.cpu}";

  mkKernel = band: arch: c: flake.buildKernel {
    inherit (bands.${band}) version src;
    inherit arch;
    defconfig = c.defconfig;
    configEnable = c.configEnable or [ ];
    configDisable = c.configDisable or [ ];
    archMakeVars = c.archMakeVars or { };
    dtbs = lib.optional (c ? dtb) c.dtb;
    buildModules = false;   # boot smoke test: kernel image only
  };

  dtbArg = c: kernel: lib.optionalString (c ? dtb) "-dtb ${kernel}/dtbs/${c.dtb}";

  qemuCmd = c: kernel: ''
    ${c.qemuSystem} -M ${c.machine} ${cpuArg c} -m ${c.mem or defMem} \
      -kernel ${kernel}/${kernel.bootImageFile} ${dtbArg c kernel} \
      -append '${c.cmdline}' \
      -nographic -no-reboot ${c.extraArgs or ""}'';

  mkBootTest = name: band: arch: c: kernel:
    pkgs.runCommand "boot-${name}"
      { nativeBuildInputs = [ pkgs.qemu ]; }
      ''
        echo "=== booting ${band} ${arch} on ${c.qemuSystem} -M ${c.machine} ==="
        set +e
        timeout 240 ${qemuCmd c kernel} > boot.log 2>&1
        set -e
        echo "--- boot.log (last 60 lines) ---"; tail -n 60 boot.log || true
        echo "---------------------------------"
        if grep -Eq '${rootMarker}' boot.log; then
          echo "BOOT OK (${name}): reached root-fs stage"
          mkdir -p $out
          cp boot.log $out/boot.log
          grep -Eo 'Linux version [^ ]+ .*' boot.log | head -1 > $out/banner || true
        else
          echo "BOOT FAILED (${name}): root-fs marker not found" >&2
          exit 1
        fi
      '';

  mkRunner = name: band: arch: c: kernel:
    pkgs.writeShellScriptBin "boot-${name}" ''
      export PATH=${pkgs.qemu}/bin:$PATH
      echo "booting ${band} ${arch} (${c.machine}); quit with Ctrl-A x" >&2
      exec ${qemuCmd c kernel}
    '';

  # Flatten (band, arch) -> one record per cell, keyed "<bandKey>-<arch>".
  cellList = lib.flatten (lib.mapAttrsToList
    (band: arches: lib.mapAttrsToList
      (arch: spec: rec {
        name = "${bandKey band}-${arch}";
        inherit band arch spec;
        kernel = mkKernel band arch spec;
      })
      arches)
    bootTable);

  bootable = builtins.filter (e: !(e.spec.buildOnly or false)) cellList;

  kernels = lib.listToAttrs (map (e: { inherit (e) name; value = e.kernel; }) cellList);
  tests = lib.listToAttrs (map
    (e: { inherit (e) name; value = mkBootTest e.name e.band e.arch e.spec e.kernel; })
    bootable);
  runners = lib.listToAttrs (map
    (e: { inherit (e) name; value = mkRunner e.name e.band e.arch e.spec e.kernel; })
    bootable);

  farm = fname: names: pkgs.linkFarm fname
    (map (n: { name = n; path = tests.${n}; }) names);
  bandNames = bk: map (e: e.name) (builtins.filter (e: bandKey e.band == bk) bootable);
in
{
  inherit tests kernels runners;

  # aggregate boot-test of every bootable cell across all bands
  all = farm "boot-all" (lib.attrNames tests);
  # per-band aggregates
  k26 = farm "boot-k26" (bandNames "k26");
  k3 = farm "boot-k3" (bandNames "k3");
  k4 = farm "boot-k4" (bandNames "k4");
  k6 = farm "boot-k6" (bandNames "k6");

  # every kernel (incl. build-only cells like k2.6 ppc64)
  kernels-all = pkgs.linkFarm "boot-kernels-all"
    (lib.mapAttrsToList (n: v: { name = n; path = v; }) kernels);
}
