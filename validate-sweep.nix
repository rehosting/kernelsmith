# The full-matrix kernel sweep: one stock kernel per band × every kernel-capable
# arch, each to a vmlinux via buildKernel. This is the check that turns the
# per-arch kernel column from "sampled" (validate-bands.nix's 5 points) into
# "swept" — toolchains existing (48/48 cells) is not the same as kernels
# building; per-arch kbuild quirks (ppc64 ELFv1 vs v2, MIPS64 ABIs, x86 under
# new gcc) only surface here.
#
#   nix build -f validate-sweep.nix all --keep-going
#   nix build -f validate-sweep.nix k26 --keep-going    # one band
#   nix build -f validate-sweep.nix cells.k26-mipseb    # one cell
#
# Cell exclusions (documented, not oversights):
#   - powerpcle: mainline Linux has NO 32-bit powerpc-LE port at any version —
#     that matrix cell is a userland/guest-binary target only, never a kernel.
#   - k2.6 arm64: the arm64 port landed in 3.7.
#   - k2.6 powerpc64le: ppc64 LE support landed ~3.10.
#
# Defconfig choices are endianness/width-definite boards where possible:
#   ip22 = SGI Indy (MIPS32 BE), ip27 = SGI Origin (MIPS64 BE),
#   fulong/fuloong2e = Loongson 2E (MIPS64 LE; renamed after 2.6),
#   pmac32 = PowerMac G4 (PPC32 BE), ppc64 = PPC64 BE,
#   pseries_le / powernv = PPC64 LE (pseries_le removed by 6.x; powernv is LE).
{}:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  src = url: sha256: pkgs.fetchurl { inherit url sha256; };
  kernels = {
    "k2.6" = {
      version = "2.6.31";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-2.6.31.tar.xz"
        "02p8kg2n2d6i9r1hkyd7mdbz92xiiz7jpb851bx71w90r8rxzl2a";
    };
    k3 = {
      version = "3.18.140";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.140.tar.xz"
        "sha256-GMOJAcUTc4U0NdNkQiwZMe0FILFsxK6UQNeyCVvc4uA=";
    };
    k4 = {
      version = "5.10";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.tar.xz"
        "sha256-3N+Z5D6YMw2SUBaYW/vHuDxm02e3FLLeDLv8v4PYykM=";
    };
    k6 = {
      version = "6.6";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz"
        "sha256-2SagbGPdisffP4buH/ws4qO4Gi0WhITna1s4mrqOVtA=";
    };
  };

  # band -> arch -> in-tree defconfig target (absence = excluded cell).
  # Verified against each tarball's arch/*/configs/ listing.
  table = {
    "k2.6" = {
      armel = "versatile_defconfig";        # validated 2026-06-29
      armhf = "omap_3430sdp_defconfig";     # Cortex-A8 (ARMv7): matches the VFP toolchain
      mipseb = "ip22_defconfig";
      mipsel = "malta_defconfig";
      mips64eb = "ip27_defconfig";
      mips64el = "fulong_defconfig";        # pre-rename spelling of fuloong2e
      powerpc = "pmac32_defconfig";
      # pseries (not ppc64_defconfig): the kitchen-sink ppc64_defconfig drags in
      # the legacy iSeries platform, whose exception.o has its own ADDR16_HI
      # overflow. pseries is the realistic ppc64 target; + FTRACE off (kernel.nix).
      powerpc64 = "pseries_defconfig";
      x86_64 = "x86_64_defconfig";
    };
    k3 = {
      armel = "versatile_defconfig";
      armhf = "vexpress_defconfig";
      arm64 = "defconfig";
      mipseb = "ip22_defconfig";
      mipsel = "malta_defconfig";           # validated 2026-06-30
      mips64eb = "ip27_defconfig";
      mips64el = "fuloong2e_defconfig";
      powerpc = "pmac32_defconfig";         # from-source mcm cell (no Bootlin gcc-6 musl)
      powerpc64 = "ppc64_defconfig";
      powerpc64le = "pseries_le_defconfig";
      x86_64 = "x86_64_defconfig";          # validated 2026-06-30 (from-source path)
    };
    k4 = {
      armel = "versatile_defconfig";
      armhf = "vexpress_defconfig";
      arm64 = "defconfig";                  # validated 2026-06-30
      mipseb = "ip22_defconfig";
      mipsel = "malta_defconfig";
      mips64eb = "ip27_defconfig";
      mips64el = "fuloong2e_defconfig";
      powerpc = "pmac32_defconfig";
      powerpc64 = "ppc64_defconfig";
      powerpc64le = "powernv_defconfig";
      x86_64 = "x86_64_defconfig";
    };
    k6 = {
      armel = "versatile_defconfig";
      armhf = "vexpress_defconfig";
      arm64 = "defconfig";
      mipseb = "ip22_defconfig";
      mipsel = "malta_defconfig";
      mips64eb = "ip27_defconfig";
      mips64el = "fuloong2e_defconfig";
      powerpc = "pmac32_defconfig";
      powerpc64 = "ppc64_defconfig";
      powerpc64le = "powernv_defconfig";
      x86_64 = "x86_64_defconfig";          # validated 2026-06-30
    };
  };

  # "k2.6" -> "k26" for derivation/attr-name friendliness
  bandKey = band: lib.replaceStrings [ "." ] [ "" ] band;

  cells = lib.foldl' (acc: band:
    acc // (lib.mapAttrs' (arch: defconfig: {
      name = "${bandKey band}-${arch}";
      value = flake.buildKernel {
        inherit (kernels.${band}) version src;
        inherit arch defconfig;
        buildModules = false; # sweep = vmlinux smoke test
      };
    }) table.${band})
  ) { } (lib.attrNames table);

  farm = name: pred: pkgs.linkFarm name
    (lib.mapAttrsToList (n: v: { name = n; path = v; })
      (lib.filterAttrs (n: _: pred n) cells));
in
{
  inherit cells;
  k26 = farm "sweep-k26" (lib.hasPrefix "k26-");
  k3 = farm "sweep-k3" (lib.hasPrefix "k3-");
  k4 = farm "sweep-k4" (lib.hasPrefix "k4-");
  k6 = farm "sweep-k6" (lib.hasPrefix "k6-");
  all = farm "sweep-all" (_: true);
}
