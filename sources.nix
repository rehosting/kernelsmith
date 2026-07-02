# Pinned component sources for musl-cross-make (the from-source FALLBACK path).
#
# mcm normally wgets these at build time; the Nix sandbox forbids network, so we
# fetch them here (content-addressed) and stage them into mcm's sources/ dir.
# Filenames MUST match exactly what mcm expects (incl. extension — mcm greps
# sources/<pkg>-<ver>.tar.<ext> and verifies against its hashes/ dir), so the
# extensions below mirror mcm's hashes/ entries: gcc/binutils/gmp/mpfr=bz2,
# musl/mpc=gz, linux=xz.
#
# All four eras are pinned with real hashes. Every version here is one that
# musl-cross-make ships a hashes/<pkg-ver>.sha1 for — mcm refuses to build a
# component it has no blessed hash for, so the matrix versions are reconciled to
# mcm's blessed set (see matrix.nix). The k2.6 band (gcc 5.3.0) is the one
# Bootlin can't supply; the k3/k4/k6 component sets here back the Bootlin-
# uncovered cells only (mips64eb/el, powerpcle at every modern band; powerpc and
# x86_64 at k3) — covered cells use the vendored Bootlin toolchains instead.
{ pkgs }:
let
  inherit (pkgs) fetchurl lib;
  gnu = path: "https://ftp.gnu.org/gnu/${path}";
  mirror = import ./mirror.nix { inherit lib; };
  # fetch mirror-first, upstream-fallback (see mirror.nix)
  fetch = url: sha256: fetchurl { urls = mirror.mirrored url; inherit sha256; };
in
{
  # ---- k2.6 era: musl-cross-make's blessed old set (it ships these hashes) ----
  "binutils-2.27" = fetch (gnu "binutils/binutils-2.27.tar.bz2")
    "sha256-Npc3zlFYf5JGYEGperfSNYxtnhtkkLOUDrCfsKmmrIg=";
  "gcc-4.2.1" = fetch (gnu "gcc/gcc-4.2.1/gcc-4.2.1.tar.bz2")
    "sha256-ygoSaVs7zPqGKFCeCMue19jtSN7/CimeTLjeh9LB/O0=";
  "gcc-4.7.4" = fetch (gnu "gcc/gcc-4.7.4/gcc-4.7.4.tar.bz2")
    "sha256-kuYcbcOgpEnmLXKjgYX9pVAWioZwLeoHEl69PsOZYoI=";
  # gcc 4.9.4 = the k2.6 band's true era-appropriate compiler. Last/most-robust
  # 4.x; unlike 4.7.4 its in-tree build detects modern mpfr/mpc correctly. Not in
  # mcm's blessed hashes/ set — mk-cross-toolchain synthesizes the hash entry.
  "gcc-4.9.4" = fetch (gnu "gcc/gcc-4.9.4/gcc-4.9.4.tar.bz2")
    "sha256-bBHSks0BspT5+EyaWcIw2A6eSkflxjVfBGuzbU81gJI=";
  "gcc-5.3.0" = fetch (gnu "gcc/gcc-5.3.0/gcc-5.3.0.tar.bz2")
    "sha256-uE9Vkukhi3PbrmErUlMDWns0qaH3aI0uG/qvcmfVxNs=";
  "musl-1.1.24" = fetch "https://musl.libc.org/releases/musl-1.1.24.tar.gz"
    "sha256-E3DJqBKyzyp9koAlEMygBYzDfmanvt1wBR8KNAFQIqM=";
  "gmp-6.1.2" = fetch (gnu "gmp/gmp-6.1.2.tar.bz2")
    "sha256-UnW7BPSGOhNRay85OSrF4nL14buAV7GK7Bybedc9j7I=";
  "mpc-1.1.0" = fetch (gnu "mpc/mpc-1.1.0.tar.gz")
    "sha256-aYXFOBQ8EgjcsaxCztrW/1LiZ7R+X5cBg6PnUSW0PC4=";
  "mpfr-4.0.2" = fetch (gnu "mpfr/mpfr-4.0.2.tar.bz2")
    "sha256-wF4/AtCeDpAZOEzdWODxnGTm2x/W9ez3e0scYcolOsw=";

  # Era-appropriate support libs for the true gcc-4.x k2.6 toolchain: gcc 4.7.4
  # (2012) predates mpfr 4.x's API removals and won't build against mpfr>=4.0,
  # so it needs mpfr 3.1.x + mpc 1.0.3 + gmp 6.1.0 (all mcm-blessed).
  "gmp-6.1.0" = fetch (gnu "gmp/gmp-6.1.0.tar.bz2")
    "sha256-SYRJqZTv66UniFwQQFmTQnmV0/hrh2jYzfjZ3Xxrc+g=";
  "mpc-1.0.3" = fetch (gnu "mpc/mpc-1.0.3.tar.gz")
    "sha256-YX3sxuoJiJ+wjt4zCRegCxaAm424jCnDG/u0nL+I7MM=";
  "mpfr-3.1.4" = fetch (gnu "mpfr/mpfr-3.1.4.tar.bz2")
    "sha256-0xA6gM2tJAftWB82GMS+0E4MktHPdxpl6tZizDl/d3U=";
  "linux-4.19.90" = fetch "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.19.90.tar.xz"
    "sha256-KdhsCm2vFp7AtLQqEvjVXciUxSvZAfh29SoFkGpc9/0=";

  # ---- k3 era (gcc 6.5.0): reuses the k2.6 binutils/musl/gmp/mpc/mpfr/linux ----
  "gcc-6.5.0" = fetch (gnu "gcc/gcc-6.5.0/gcc-6.5.0.tar.xz")
    "sha256-fvF5bOSX6JR5GDcCY1sUu3pGtTJJIJpeD5mb6/R0CUU=";

  # ---- k4 era (gcc 9.4.0, binutils 2.33.1, musl 1.2.4) ----
  "gcc-9.4.0" = fetch (gnu "gcc/gcc-9.4.0/gcc-9.4.0.tar.xz")
    "sha256-yV2jL0QDeNd1HdlVMxhvf8Bc60+2XrW4UjTmKZ65g44=";
  "binutils-2.33.1" = fetch (gnu "binutils/binutils-2.33.1.tar.xz")
    "sha256-q2b8LRw+wDWbjgiEPJ8ztj6HB+/f9eTMXCAOriRyLL8=";
  "musl-1.2.4" = fetch "https://musl.libc.org/releases/musl-1.2.4.tar.gz"
    "sha256-ejXq4z1TcqfA2hGI3nmHJvaIJVE7euPr6XqqpSEU8Dk=";

  # ---- k6 era (gcc 13.3.0, binutils 2.44, gmp 6.3.0, mpc 1.3.1, mpfr 4.2.2) ----
  "gcc-13.3.0" = fetch (gnu "gcc/gcc-13.3.0/gcc-13.3.0.tar.xz")
    "sha256-CEXpYhyVQ6E/SE6UWEpJ/8ASmXDpkUYkI1/B0GGgwIM=";
  "binutils-2.44" = fetch (gnu "binutils/binutils-2.44.tar.gz")
    "sha256-DN12d3oN/T3Tpj8hXwMCCN25HCNh0rzAKs7A8cFrai4=";
  "gmp-6.3.0" = fetch (gnu "gmp/gmp-6.3.0.tar.xz")
    "sha256-o8K4AgG4nmhhb0rTC8Zq7kknw85Q4zkpyoGdXENTiJg=";
  "mpc-1.3.1" = fetch (gnu "mpc/mpc-1.3.1.tar.gz")
    "sha256-q2QkkvXPiCt0qgy3MM1BCoHtzb7IlRg86TDnBsHHWbg=";
  "mpfr-4.2.2" = fetch (gnu "mpfr/mpfr-4.2.2.tar.xz")
    "sha256-tnugOD736KhWNzTi6InvXsPDuJigHQD6CmhprYHGzgE=";
}
