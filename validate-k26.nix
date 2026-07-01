# Validation: can the k2.6 toolchain (gcc 5.3.0) build a real 2.6.x kernel?
#
# This is the empirical check behind the "accept gcc 5.3.0 for k2.6 provisionally"
# decision — it exercises the exact upper-bound risks (asm-goto, -Werror, dropped
# C dialects) that a too-new gcc would trip on an old tree.
#
# Stock kernel.org 2.6.31 + an in-tree ARM board defconfig. A firmware-specific
# config adds nothing to the gcc-compat question, so we smoke-test the stock
# tree for reproducibility.
#
#   nix-build validate-k26.nix
{}:
let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
in
flake.buildKernel {
  version = "2.6.31";
  arch = "armel";
  src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-2.6.31.tar.xz";
    sha256 = "02p8kg2n2d6i9r1hkyd7mdbz92xiiz7jpb851bx71w90r8rxzl2a";
  };
  defconfig = "versatile_defconfig";
  buildModules = false; # smoke test: vmlinux is enough to prove the toolchain
}
