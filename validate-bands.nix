# Cross-band buildKernel validation. Smoke-builds one stock kernel per modern
# era through buildKernel, exercising BOTH sourcing paths and several kbuild
# arch backends. k2.6 is covered separately by validate-k26.nix.
#
#   nix build -f validate-bands.nix all     # all targets
#   nix build -f validate-bands.nix k3-mipsel
#
# Targets (version -> era is auto-resolved by resolve.nix):
#   k3-mipsel  3.18.140  Bootlin k3 (gcc 6.4) — real rehosting arch, mips kbuild
#   k3-x86_64  3.18.140  musl-cross-make k3 (gcc 6.5) — the FROM-SOURCE path in buildKernel
#   k4-arm64   5.10      Bootlin k4 (gcc 9.3)
#   k6-x86_64  6.6       Bootlin k6 (gcc 13.3)
{}:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };

  k = { version, arch, defconfig, src }:
    flake.buildKernel {
      inherit version arch defconfig src;
      buildModules = false; # smoke test: vmlinux proves the toolchain end-to-end
    };

  src = url: sha256: pkgs.fetchurl { inherit url sha256; };
  v3 = src "https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.140.tar.xz"
        "sha256-GMOJAcUTc4U0NdNkQiwZMe0FILFsxK6UQNeyCVvc4uA=";
  v5 = src "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.tar.xz"
        "sha256-3N+Z5D6YMw2SUBaYW/vHuDxm02e3FLLeDLv8v4PYykM=";
  v6 = src "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz"
        "sha256-2SagbGPdisffP4buH/ws4qO4Gi0WhITna1s4mrqOVtA=";

  targets = {
    k3-mipsel = k { version = "3.18.140"; arch = "mipsel"; defconfig = "malta_defconfig"; src = v3; };
    k3-x86_64 = k { version = "3.18.140"; arch = "x86_64"; defconfig = "x86_64_defconfig"; src = v3; };
    k4-arm64  = k { version = "5.10";     arch = "arm64";  defconfig = "defconfig";        src = v5; };
    k6-x86_64 = k { version = "6.6";      arch = "x86_64"; defconfig = "x86_64_defconfig"; src = v6; };
  };
in
targets // {
  all = pkgs.linkFarm "validate-bands"
    (pkgs.lib.mapAttrsToList (n: v: { name = n; path = v; }) targets);
}
