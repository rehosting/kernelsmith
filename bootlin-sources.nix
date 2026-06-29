# Pinned Bootlin prebuilt toolchain tarballs (the k3/k4/k6 sourcing path).
#
# Keyed "<matrix-arch>-<era>". Each entry: { tarball = fetchurl; target = <buildroot
# triple>; crossAlias = <short CROSS_COMPILE prefix>; }.
# Hashes via `nix store prefetch-file <url>`. Should ultimately be MIRRORED to Harbor —
# upstream pinned URLs are not "reproducible forever".
#
# Bootlin's oldest release is gcc 5.4.0 (2017.05). The k2.6 band (gcc 4.x) is absent
# here by design → musl-cross-make (mk-cross-toolchain.nix).
#
# Arches Bootlin does NOT cover with a modern musl toolchain (→ musl-cross-make even
# for k3/k4/k6):
#   - powerpcle : Bootlin has no 32-bit powerpc little-endian variant at all.
#   - mips64el  : Bootlin only ships it as n32 ABI (mips64el-n32), not the n64 our
#                 mips64el-linux-musl target expects → ABI mismatch.
#   - mips64eb  : the plain `mips64` dir has musl only at 2017.05 (gcc 5.4); newer
#                 releases dropped musl for it → no modern band from Bootlin.
{ pkgs }:
let
  inherit (pkgs) fetchurl;
  base = "https://toolchains.bootlin.com/downloads/releases/toolchains";

  # matrix-arch -> Bootlin (arch-dir, buildroot triple, short CROSS_COMPILE alias)
  archMap = {
    armel       = { dir = "armv5-eabi";          target = "arm-buildroot-linux-musleabi";    alias = "arm-linux-"; };
    armhf       = { dir = "armv7-eabihf";         target = "arm-buildroot-linux-musleabihf";  alias = "arm-linux-"; };
    arm64       = { dir = "aarch64";              target = "aarch64-buildroot-linux-musl";     alias = "aarch64-linux-"; };
    mipseb      = { dir = "mips32";               target = "mips-buildroot-linux-musl";        alias = "mips-linux-"; };
    mipsel      = { dir = "mips32el";             target = "mipsel-buildroot-linux-musl";      alias = "mipsel-linux-"; };
    powerpc     = { dir = "powerpc-e300c3";       target = "powerpc-buildroot-linux-musl";     alias = "powerpc-linux-"; };
    powerpc64   = { dir = "powerpc64-power8";     target = "powerpc64-buildroot-linux-musl";   alias = "powerpc64-linux-"; };
    powerpc64le = { dir = "powerpc64le-power8";   target = "powerpc64le-buildroot-linux-musl"; alias = "powerpc64le-linux-"; };
    x86_64      = { dir = "x86-64";               target = "x86_64-buildroot-linux-musl";      alias = "x86_64-linux-"; };
  };

  # Build one pinned entry from (matrix-arch, release-file, sha256).
  entry = arch: file: sha256:
    let a = archMap.${arch}; in {
      target = a.target;
      crossAlias = a.alias;
      tarball = fetchurl { url = "${base}/${a.dir}/tarballs/${file}"; inherit sha256; };
    };

  # k6 band: Buildroot 2024.05-1 == gcc 13.3.0, musl, across all 9 covered arches.
  k6file = arch: "${archMap.${arch}.dir}--musl--stable-2024.05-1.tar.xz";
  k6 = arch: sha256: { name = "${arch}-k6"; value = entry arch (k6file arch) sha256; };
in
builtins.listToAttrs [
  (k6 "armel"       "sha256-mCXZpFFaktIlGqsyKN27YlhECw+VK5X8qpRlOkspxxo=")
  (k6 "armhf"       "sha256-WzQVekyfUwZAAvEvV8QoNs1VHFkaS+apmz7iAa3VBqo=")
  (k6 "arm64"       "sha256-+EfaEZUyVSXz8H7vBF70DGtIRko34Pf+p3Ng3+C8GqE=")
  (k6 "mipseb"      "sha256-9VOux2C/yfRS8asHGyW4T9Nu1Wq0x1FJs1EURWG04LU=")
  (k6 "mipsel"      "sha256-YIsbJDSvVjUT3yGuCmq1Kvige3Kkvadg35RkGc3SZFo=")
  (k6 "powerpc"     "sha256-YPtrgo5YtVSFFP1lxQRX0ZB5EZHTp9zsH7938AKLwkA=")
  (k6 "powerpc64"   "sha256-1fko7ZndT32uXEs9R8D0Y6mQt3RIZtibqC4Ip+6fmoo=")
  (k6 "powerpc64le" "sha256-YvBWtZk/bRvy2Uph0B4dSqpYkGEH2zrxGsiCyYntfB0=")
  (k6 "x86_64"      "sha256-889BfSjn35W9q2Mv+DfeZqwDFFvQ4d14zImq36bjFSY=")
]
