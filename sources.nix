# Pinned component sources for musl-cross-make.
#
# mcm normally wgets these at build time; the Nix sandbox forbids network, so we
# fetch them here (content-addressed) and stage them into mcm's sources/ dir.
# The filenames MUST match exactly what mcm's Makefile expects (it greps
# sources/<pkg>-<ver>.tar.*), and mcm verifies each against its own hashes/ dir,
# so our sha256 + mcm's sha1 both gate the input.
#
# To fill a hash: `nix store prefetch-file <url>` (or set to lib.fakeSha256 and
# let the first build print the correct one).
{ pkgs }:
let
  inherit (pkgs) fetchurl;
  fake = pkgs.lib.fakeSha256; # replace per-entry as builds surface real hashes

  # GNU mirror is the most reliable; musl.libc.org for musl itself.
  gnu = path: "https://ftpmirror.gnu.org/${path}";
in
{
  # ---- binutils ----
  "binutils-2.27" = fetchurl { url = gnu "binutils/binutils-2.27.tar.bz2"; sha256 = fake; };
  "binutils-2.33.1" = fetchurl { url = gnu "binutils/binutils-2.33.1.tar.xz"; sha256 = fake; };
  "binutils-2.41" = fetchurl { url = gnu "binutils/binutils-2.41.tar.xz"; sha256 = fake; };

  # ---- gcc (the version-band that matters) ----
  # 4.x band -> ancient kernels (2.6 / early 3.x)
  "gcc-4.9.4" = fetchurl { url = gnu "gcc/gcc-4.9.4/gcc-4.9.4.tar.bz2"; sha256 = fake; };
  # 6.x band -> 3.x / early 4.x (matches today's legacy mips/x86_64-legacy stages)
  "gcc-6.5.0" = fetchurl { url = gnu "gcc/gcc-6.5.0/gcc-6.5.0.tar.xz"; sha256 = fake; };
  # 9.x band -> 4.x / 5.x
  "gcc-9.4.0" = fetchurl { url = gnu "gcc/gcc-9.4.0/gcc-9.4.0.tar.xz"; sha256 = fake; };
  # 13.x band -> 6.x
  "gcc-13.2.0" = fetchurl { url = gnu "gcc/gcc-13.2.0/gcc-13.2.0.tar.xz"; sha256 = fake; };

  # ---- musl ----
  "musl-1.1.24" = fetchurl { url = "https://musl.libc.org/releases/musl-1.1.24.tar.gz"; sha256 = fake; };
  "musl-1.2.4" = fetchurl { url = "https://musl.libc.org/releases/musl-1.2.4.tar.gz"; sha256 = fake; };

  # ---- gcc prerequisites ----
  "gmp-6.1.2" = fetchurl { url = gnu "gmp/gmp-6.1.2.tar.bz2"; sha256 = fake; };
  "gmp-6.2.1" = fetchurl { url = gnu "gmp/gmp-6.2.1.tar.bz2"; sha256 = fake; };
  "mpc-1.1.0" = fetchurl { url = gnu "mpc/mpc-1.1.0.tar.gz"; sha256 = fake; };
  "mpc-1.3.1" = fetchurl { url = gnu "mpc/mpc-1.3.1.tar.gz"; sha256 = fake; };
  "mpfr-4.0.2" = fetchurl { url = gnu "mpfr/mpfr-4.0.2.tar.xz"; sha256 = fake; };
  "mpfr-4.2.1" = fetchurl { url = gnu "mpfr/mpfr-4.2.1.tar.xz"; sha256 = fake; };

  # ---- linux headers (mcm uses these for the sysroot) ----
  "linux-4.19.317" = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.19.317.tar.xz";
    sha256 = fake;
  };
}
