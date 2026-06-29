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
    # Linux 2.6 / early 3.x
    "k2.6" = {
      gccVer = "4.9.4"; binutilsVer = "2.27"; muslVer = "1.1.24";
      gmpVer = "6.1.2"; mpcVer = "1.1.0"; mpfrVer = "4.0.2"; linuxVer = "4.19.317";
    };
    # 3.x / early 4.x (matches the x86_64-legacy + mips gcc-6.5 stages today)
    "k3" = {
      gccVer = "6.5.0"; binutilsVer = "2.27"; muslVer = "1.1.24";
      gmpVer = "6.1.2"; mpcVer = "1.1.0"; mpfrVer = "4.0.2"; linuxVer = "4.19.317";
    };
    # 4.x / 5.x  (the current default era)
    "k4" = {
      gccVer = "9.4.0"; binutilsVer = "2.33.1"; muslVer = "1.2.4";
      gmpVer = "6.1.2"; mpcVer = "1.1.0"; mpfrVer = "4.0.2"; linuxVer = "4.19.317";
    };
    # 6.x
    "k6" = {
      gccVer = "13.2.0"; binutilsVer = "2.41"; muslVer = "1.2.4";
      gmpVer = "6.2.1"; mpcVer = "1.3.1"; mpfrVer = "4.2.1"; linuxVer = "4.19.317";
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
