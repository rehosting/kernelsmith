# Pinned Bootlin prebuilt toolchain tarballs (the k3/k4/k6 sourcing path).
#
# Keyed "<matrix-arch>-<era>". Each entry: { tarball = fetchurl; target = <buildroot
# triple>; crossAlias = <short CROSS_COMPILE prefix>; }.
# Hashes via `nix store prefetch-file <url>`. Should ultimately be MIRRORED to Harbor —
# upstream pinned URLs are not "reproducible forever".
#
# An era maps a kernel generation to a gcc FLOOR; per cell we pick the nearest available
# Bootlin release whose gcc clears that floor. Release->gcc (verified from tarball
# listings): 2018.02=6.4.0, 2018.11=7.3.0, 2020.02=8.4.0, 2020.08=9.3.0, 2021.11=10.3.0,
# 2024.05=13.3.0. Note release date != era — we pick by the gcc inside, not the year.
#
# Per-arch musl availability is IRREGULAR for older releases, so a band is not one
# uniform release: x86_64 musl starts only at 2021.11; powerpc-e300c3 musl only at 2020.08.
#
# Bootlin's oldest release is gcc 5.4.0 (2017.05); k2.6 (gcc 4.x) is absent → musl-cross-make.
# Arches with NO modern Bootlin musl at all (→ musl-cross-make for every band):
#   - powerpcle : no 32-bit powerpc little-endian variant exists.
#   - mips64el  : only n32 ABI (mips64el-n32), not the n64 our target wants.
#   - mips64eb  : `mips64` has musl only at 2017.05 (gcc 5.4); newer releases dropped it.
{ pkgs }:
let
  inherit (pkgs) fetchurl lib;
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

  # Bootlin switched .tar.bz2 -> .tar.xz at the 2024.05 release.
  xzReleases = [ "2024.05-1" "2025.08-1" ];
  ext = release: if builtins.elem release xzReleases then "xz" else "bz2";

  # (matrix-arch, band, release, sha256) -> { name = "<arch>-<band>"; value = entry; }
  t = arch: band: release: sha256:
    let a = archMap.${arch}; in {
      # key "<era>-<arch>" to match resolve.toolchainKey / the mcm matrix
      name = "${band}-${arch}";
      value = {
        target = a.target;
        crossAlias = a.alias;
        tarball = fetchurl {
          url = "${base}/${a.dir}/tarballs/${a.dir}--musl--stable-${release}.tar.${ext release}";
          inherit sha256;
        };
      };
    };
in
builtins.listToAttrs [
  # ---- k6: gcc 13.3.0 (Buildroot 2024.05-1), all 9 covered arches ----
  (t "armel"       "k6" "2024.05-1" "sha256-mCXZpFFaktIlGqsyKN27YlhECw+VK5X8qpRlOkspxxo=")
  (t "armhf"       "k6" "2024.05-1" "sha256-WzQVekyfUwZAAvEvV8QoNs1VHFkaS+apmz7iAa3VBqo=")
  (t "arm64"       "k6" "2024.05-1" "sha256-+EfaEZUyVSXz8H7vBF70DGtIRko34Pf+p3Ng3+C8GqE=")
  (t "mipseb"      "k6" "2024.05-1" "sha256-9VOux2C/yfRS8asHGyW4T9Nu1Wq0x1FJs1EURWG04LU=")
  (t "mipsel"      "k6" "2024.05-1" "sha256-YIsbJDSvVjUT3yGuCmq1Kvige3Kkvadg35RkGc3SZFo=")
  (t "powerpc"     "k6" "2024.05-1" "sha256-YPtrgo5YtVSFFP1lxQRX0ZB5EZHTp9zsH7938AKLwkA=")
  (t "powerpc64"   "k6" "2024.05-1" "sha256-1fko7ZndT32uXEs9R8D0Y6mQt3RIZtibqC4Ip+6fmoo=")
  (t "powerpc64le" "k6" "2024.05-1" "sha256-YvBWtZk/bRvy2Uph0B4dSqpYkGEH2zrxGsiCyYntfB0=")
  (t "x86_64"      "k6" "2024.05-1" "sha256-889BfSjn35W9q2Mv+DfeZqwDFFvQ4d14zImq36bjFSY=")

  # ---- k4: gcc 9.3.0 (2020.08-1); x86_64 has no musl that old -> 2021.11-5 (gcc 10.3) ----
  (t "armel"       "k4" "2020.08-1" "sha256-cy7atXHQF8VQ10uMU9xwP8ZQ3nqrZuaMcKC8GdZtCiI=")
  (t "armhf"       "k4" "2020.08-1" "sha256-XEybzloqRqmtRuSeht9wiJOokH5wKo7htf69OVDgMO0=")
  (t "arm64"       "k4" "2020.08-1" "sha256-gxnSfj5jfzLsvfSc7uLpt3aLMtPsfJLIiP9S5vBiveQ=")
  (t "mipseb"      "k4" "2020.08-1" "sha256-GlRCQumqrudcJAQ5ox0vQwS5dwXtLZ6eOMpVLF8D3O0=")
  (t "mipsel"      "k4" "2020.08-1" "sha256-AhVciOC/kvYxBYA3Z85Fd5C/2SApfvMmyZIIU7Wj/iA=")
  (t "powerpc"     "k4" "2020.08-1" "sha256-Ep2aq1np7fxoc5thLy7kq85WeYMCUPvNULiew9LIZcU=")
  (t "powerpc64"   "k4" "2020.08-1" "sha256-EgQ6uHzUrgxDOc3cs+sBfqrkBruzMr8+3r/X9w7NCjE=")
  (t "powerpc64le" "k4" "2020.08-1" "sha256-R9GEvsonHGe9tUT6yHyyEm6is5fQdqed+vlmfpmfvM0=")
  (t "x86_64"      "k4" "2021.11-5" "sha256-KUNhf2U3yhlaZvudtKgBpd0cEIdBxADVMNVY0GkI3XU=")

  # ---- k3: gcc 6.4.0 (2018.02-1). powerpc (musl starts 2020.08) and x86_64 (musl starts
  #          2021.11) have NO gcc-6 musl -> deferred; forcing newer gcc on 3.x is an
  #          upper-bound risk to validate empirically, or use musl-cross-make for those two.
  (t "armel"       "k3" "2018.02-1" "sha256-5YqkTvJ2NAon85V+gwjlMjBJ1O0b6zXwdngEc8j8svo=")
  (t "armhf"       "k3" "2018.02-1" "sha256-tAlcORp3ENsgU/P5Bng4FmqdbwNsO6ydT2x1DKTYQyg=")
  (t "arm64"       "k3" "2018.02-1" "sha256-z7ZLMuxIJUEKfNaTofm1OzYY0WdgfRTkZCsBGTbyOgU=")
  (t "mipseb"      "k3" "2018.02-1" "sha256-H9YH+Ujpyf8gp2rRq7uHKWwWRoP+1JW4DUYkaUuyNxU=")
  (t "mipsel"      "k3" "2018.02-1" "sha256-l+EQR29vY7BW4viR42wS8CQpWFVULIxnPWkF0cF8f5w=")
  (t "powerpc64"   "k3" "2018.02-1" "sha256-3BmAnSmSOB5ZwHVYMhBKTONTeFWrMr3/ayynIpVly/w=")
  (t "powerpc64le" "k3" "2018.02-1" "sha256-l5awy4OTDAo2/y1mxW3imC+/opfijZMekP6mFKk9UqQ=")
]
