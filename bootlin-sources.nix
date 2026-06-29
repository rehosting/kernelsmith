# Pinned Bootlin prebuilt toolchain tarballs (the k3/k4/k6 sourcing path).
#
# Each entry: { tarball = fetchurl; target = <buildroot triple>; crossAlias = ...; }.
# Hashes via `nix store prefetch-file <url>`. These should ultimately be MIRRORED
# to Harbor — upstream URLs are not "reproducible forever" (a pinned URL can rot).
#
# Naming maps our matrix arch key -> Bootlin arch dir + release. Bootlin's oldest
# release is gcc 5.4.0 (2017.05); nothing below that, so the k2.6 band is absent
# here by design (it uses musl-cross-make).
{ pkgs }:
let
  inherit (pkgs) fetchurl;
  base = "https://toolchains.bootlin.com/downloads/releases/toolchains";
  # one Bootlin SDK tarball
  bootlin = { arch, file, sha256, target, crossAlias ? null }: {
    inherit target crossAlias;
    tarball = fetchurl {
      url = "${base}/${arch}/tarballs/${file}";
      inherit sha256;
    };
  };
in
{
  # First proven cell: mips32 (big-endian) musl, 2024.05 stable = gcc 13.3.0 (k6 band).
  "mipseb-k6" = bootlin {
    arch = "mips32";
    file = "mips32--musl--stable-2024.05-1.tar.xz";
    sha256 = "sha256-9VOux2C/yfRS8asHGyW4T9Nu1Wq0x1FJs1EURWG04LU=";
    target = "mips-buildroot-linux-musl";
    crossAlias = "mips-linux-";
  };
}
