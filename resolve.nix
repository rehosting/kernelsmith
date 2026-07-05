# Resolver: concrete kernel version -> era name.
#
# This is the dispatch that lets you say "build 3.18.140 for mipsel" and have
# the system pick the right toolchain. Boundaries encode the HARD constraint —
# the gcc upper bound a given kernel generation can be compiled with — not
# preference. Ordered low->high; first matching range wins.
{ lib }:
let
  # Each entry: kernels with version < `below` use era `era`.
  # Sentinel `null` = "everything at or above the previous boundary".
  bands = [
    { below = "3.0"; era = "k2.6"; } # 2.6.x: gcc must be <= ~4.9
    { below = "4.0"; era = "k3"; } #   3.x:   gcc <= ~6
    { below = "6.0"; era = "k4"; } #   4.x/5.x: gcc 9 band
    { below = null; era = "k6"; } #    6.x+:  gcc 13 band
  ];
in
rec {
  # "2.6.39.4" -> "k2.6"; "5.10.200" -> "k4"; "6.6.1" -> "k6"
  eraFor =
    version:
    let
      hit = lib.findFirst (b: b.below == null || lib.versionOlder version b.below) null bands;
    in
    if hit == null then throw "resolve: no era band for kernel ${version}" else hit.era;

  # NOTE: to go from (version, arch) to an actual toolchain, use flake.nix's
  # `resolveToolchain` (or the `toolchainFor` alias) — NOT a bare "<era>-<arch>"
  # key lookup in `toolchains`, which would miss the kernel-only toolchains
  # (k2.6 band, k3-powerpc64) and hand back an ABI-mismatched compiler.
}
