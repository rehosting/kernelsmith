# Pinned component sources for musl-cross-make (the from-source FALLBACK path).
#
# mcm normally wgets these at build time; the Nix sandbox forbids network, so we
# fetch them here (content-addressed) and stage them into mcm's sources/ dir.
# Filenames MUST match exactly what mcm expects (incl. extension — mcm greps
# sources/<pkg>-<ver>.tar.<ext> and verifies against its hashes/ dir), so the
# extensions below mirror mcm's hashes/ entries: gcc/binutils/gmp/mpfr=bz2,
# musl/mpc=gz, linux=xz.
#
# Currently only the k2.6 era (gcc 4.7.4) is pinned with real hashes — that's the
# one band Bootlin can't supply (no gcc < 5.4). The other from-source cells
# (mips64eb/el/powerpcle modern bands, powerpc/x86_64 k3) are Bootlin-uncovered
# TODOs; add their component versions here when tackled.
{ pkgs }:
let
  inherit (pkgs) fetchurl;
  gnu = path: "https://ftp.gnu.org/gnu/${path}";
in
{
  # ---- k2.6 era: musl-cross-make's blessed old set (it ships these hashes) ----
  "binutils-2.27" = fetchurl {
    url = gnu "binutils/binutils-2.27.tar.bz2";
    sha256 = "sha256-Npc3zlFYf5JGYEGperfSNYxtnhtkkLOUDrCfsKmmrIg=";
  };
  "gcc-4.2.1" = fetchurl {
    url = gnu "gcc/gcc-4.2.1/gcc-4.2.1.tar.bz2";
    sha256 = "sha256-ygoSaVs7zPqGKFCeCMue19jtSN7/CimeTLjeh9LB/O0=";
  };
  "gcc-5.3.0" = fetchurl {
    url = gnu "gcc/gcc-5.3.0/gcc-5.3.0.tar.bz2";
    sha256 = "sha256-uE9Vkukhi3PbrmErUlMDWns0qaH3aI0uG/qvcmfVxNs=";
  };
  "musl-1.1.24" = fetchurl {
    url = "https://musl.libc.org/releases/musl-1.1.24.tar.gz";
    sha256 = "sha256-E3DJqBKyzyp9koAlEMygBYzDfmanvt1wBR8KNAFQIqM=";
  };
  "gmp-6.1.2" = fetchurl {
    url = gnu "gmp/gmp-6.1.2.tar.bz2";
    sha256 = "sha256-UnW7BPSGOhNRay85OSrF4nL14buAV7GK7Bybedc9j7I=";
  };
  "mpc-1.1.0" = fetchurl {
    url = gnu "mpc/mpc-1.1.0.tar.gz";
    sha256 = "sha256-aYXFOBQ8EgjcsaxCztrW/1LiZ7R+X5cBg6PnUSW0PC4=";
  };
  "mpfr-4.0.2" = fetchurl {
    url = gnu "mpfr/mpfr-4.0.2.tar.bz2";
    sha256 = "sha256-wF4/AtCeDpAZOEzdWODxnGTm2x/W9ez3e0scYcolOsw=";
  };
  "linux-4.19.90" = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.19.90.tar.xz";
    sha256 = "sha256-KdhsCm2vFp7AtLQqEvjVXciUxSvZAfh29SoFkGpc9/0=";
  };
}
