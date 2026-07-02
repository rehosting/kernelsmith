# The (gcc-era x arch) matrix, expressed as data.
#
# This is the whole point of Tier 2: adding a kernel era or an arch is an edit
# here, not a new Dockerfile stage. `eras` defines the component-version bundles
# that a given kernel generation can be built with; `arches` defines the 12 mcm
# target triples + per-arch quirks. The flake builds the cartesian product
# (skipping any (era, arch) pair listed in `unsupported`).
{ lib }:
rec {
  # Kernel-generation -> compatible tool bundle. The gcc upper-bound per kernel
  # is the hard constraint (e.g. 2.6 will not build under gcc >= 5).
  eras = {
    # Linux 2.6 / early 3.x — the from-source (musl-cross-make) band, built with
    # a TRUE era-appropriate gcc 4.9.4 (the last/most-robust 4.x). This matters:
    # gcc >=5 is too new for stock 2.6 on most arches (mips arch/mips/mm/page.c
    # aliases a function to a variable — a hard error under gcc>=5; ppc/x86 hit
    # -Werror + vDSO issues). gcc 4.9.4 predates all of that, so the full-matrix
    # kernel sweep passes where gcc 5.3.0 only managed ARM.
    # Building this old gcc under a modern host needs a few gated fixes in
    # mk-cross-toolchain.nix (all keyed off gccVer<5): refresh the pre-musl
    # config.sub/.guess, build in-tree gmp/mpfr/mpc static, and compile gcc's own
    # C++03-era source with -std=gnu++03 (host gcc 13 defaults to C++17). Support
    # libs are pinned to the gcc-4.9 era (mpfr 3.1.4 / mpc 1.0.3 / gmp 6.1.0);
    # mpfr>=4 would not build against gcc 4.9. gcc 4.9.4 is not in mcm's blessed
    # hashes/ set — mk-cross-toolchain synthesizes the entry from the staged
    # tarball. (mcm master also ships 2026 musl CVE patches that corrupt 1.1.24
    # qsort.c; mk-cross-toolchain.nix strips them.)
    "k2.6" = {
      gccVer = "4.9.4"; binutilsVer = "2.27"; muslVer = "1.1.24";
      gmpVer = "6.1.0"; mpcVer = "1.0.3"; mpfrVer = "3.1.4"; linuxVer = "4.19.90";
    };
    # NOTE: the from-source (musl-cross-make) cells below only get built for the
    # arches Bootlin can't supply (mips64eb/el, powerpcle at every modern band;
    # powerpc/x86_64 at k3) — Bootlin toolchains override the rest. Every version
    # here is reconciled to musl-cross-make's blessed hashes/ set (mcm refuses to
    # build a component version it has no .sha1 for). linuxVer = 4.19.90 across
    # the modern eras: it only supplies kernel *headers* to the libc, so the exact
    # version is immaterial and 4.19.90 is already pinned + mcm-blessed.

    # 3.x / early 4.x — gcc 6.5.0 (reuses the k2.6 support-lib set)
    "k3" = {
      gccVer = "6.5.0"; binutilsVer = "2.27"; muslVer = "1.1.24";
      gmpVer = "6.1.2"; mpcVer = "1.1.0"; mpfrVer = "4.0.2"; linuxVer = "4.19.90";
    };
    # 4.x / 5.x  (the current default era)
    "k4" = {
      gccVer = "9.4.0"; binutilsVer = "2.33.1"; muslVer = "1.2.4";
      gmpVer = "6.1.2"; mpcVer = "1.1.0"; mpfrVer = "4.0.2"; linuxVer = "4.19.90";
    };
    # 6.x  (gcc 13.3.0 — mcm blesses .3, not the .2 in the era-ideal)
    "k6" = {
      gccVer = "13.3.0"; binutilsVer = "2.44"; muslVer = "1.2.4";
      gmpVer = "6.3.0"; mpcVer = "1.3.1"; mpfrVer = "4.2.2"; linuxVer = "4.19.90";
    };
  };

  # The 12 architectures, as mcm target triples + per-arch config.mak quirks.
  arches = {
    armel        = { target = "arm-linux-musleabi"; };
    armhf        = { target = "arm-linux-musleabihf"; };
    arm64        = { target = "aarch64-linux-musl"; };
    mipseb       = { target = "mips-linux-musl";  extraConfig = [ ''GCC_CONFIG += --with-arch=mips32r2'' ]; };
    mipsel       = { target = "mipsel-linux-musl"; extraConfig = [ ''GCC_CONFIG += --with-arch=mips32r2'' ]; };
    mips64eb     = { target = "mips64-linux-musl"; };
    mips64el     = { target = "mips64el-linux-musl"; };
    powerpc      = { target = "powerpc-linux-musl"; };
    powerpcle    = { target = "powerpcle-linux-musl"; };
    powerpc64    = { target = "powerpc64-linux-musl"; };
    powerpc64le  = { target = "powerpc64le-linux-musl"; };
    x86_64       = { target = "x86_64-linux-musl"; };
  };

  # (era, arch) pairs to skip — e.g. arches that didn't exist / lack a musl port
  # in an era. Keyed "<era>.<arch>".
  unsupported = [
    # "k2.6.arm64"   # aarch64 predates 2.6-era musl; fill in as discovered
  ];
}
