# Module-build validation: prove the `dev` output of buildKernel is a build tree
# an out-of-tree module can actually compile against.
#
#   nix-build validate-module.nix -A k26     # one band (k2.6 -> k26; nix splits -A on ".")
#   nix-build validate-module.nix -A all     # every band
#
# This exists because the failure mode is quiet and late. A broken kernel-devel
# tree still *looks* fine -- it is a directory full of headers -- and the error
# surfaces in some other repo's CI as a compile failure with no obvious owner.
#
# The specific trap it guards: nixpkgs' multiple-outputs setup hook runs
# `moveToOutput include "$outputDev"`, and `outputDev` falls back to "out"
# unless some output is named literally "dev". Name the output "devel" and the
# hook relocates the build tree's include/ into $out, leaving a headerless build
# tree. The kernel build still succeeds.
#
# Checked per BAND rather than per arch: the bands are what differ in the ways
# that break kbuild (gcc 4.4 vs 13, pre/post the scripts/ rework). Arch coverage
# is the boot sweep's job.
{ }:

let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;

  src = url: sha256: pkgs.fetchurl { inherit url sha256; };

  # Same pins as boot.nix / validate-sweep.nix. Duplicated rather than imported
  # because boot.nix is a `{ }:` entrypoint that exports checks, not its table.
  bands = {
    "k2.6" = {
      version = "2.6.31";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-2.6.31.tar.xz"
        "02p8kg2n2d6i9r1hkyd7mdbz92xiiz7jpb851bx71w90r8rxzl2a";
    };
    "k3" = {
      version = "3.18.140";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.140.tar.xz"
        "sha256-GMOJAcUTc4U0NdNkQiwZMe0FILFsxK6UQNeyCVvc4uA=";
    };
    "k4" = {
      version = "5.10.229";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.229.tar.xz"
        "1q6di05rk4bsy91r03zw6vz14zzcpvv25dv7gw0yz1gzpgkbb9h8";
    };
    "k6" = {
      version = "6.6";
      src = src "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz"
        "sha256-2SagbGPdisffP4buH/ws4qO4Gi0WhITna1s4mrqOVtA=";
    };
  };

  # Deliberately trivial -- this validates the BUILD TREE, not a module. But not
  # empty: it pulls in <linux/module.h> (so the generated autoconf.h and the arch
  # headers must be present) and exports a symbol (so Module.symvers and the
  # modpost CRC path must work). An empty .c would compile against a broken tree.
  testmodSrc = pkgs.runCommand "kernelsmith-testmod-src" { } ''
    mkdir -p $out
    cat > $out/testmod.c <<'EOF'
    #include <linux/module.h>
    #include <linux/kernel.h>
    #include <linux/init.h>

    int kernelsmith_probe_value = 42;
    EXPORT_SYMBOL(kernelsmith_probe_value);

    static int __init testmod_init(void)
    {
    	pr_info("kernelsmith testmod loaded\n");
    	return 0;
    }

    static void __exit testmod_exit(void) { }

    module_init(testmod_init);
    module_exit(testmod_exit);
    MODULE_LICENSE("GPL");
    EOF
    printf 'obj-m := testmod.o\n' > $out/Makefile
  '';

  # mipsel/malta is covered by every band and is among the cheapest to build.
  checkBand = band:
    let
      kernel = flake.buildKernel {
        inherit (bands.${band}) version src;
        arch = "mipsel";
        defconfig = "malta_defconfig";
        # A module build needs modules_prepare, not the in-tree modules.
        buildModules = false;
      };
      mod = flake.buildModule {
        name = "kernelsmith-testmod-${band}";
        src = testmodSrc;
        inherit kernel;
      };
    in
    pkgs.runCommand "check-module-${band}" { } ''
      test -f ${mod}/testmod.ko || { echo "no testmod.ko for ${band}" >&2; exit 1; }
      ${pkgs.file}/bin/file -b ${mod}/testmod.ko > $out
      cat $out
      # Prove it is a target object, not a host build that happened to succeed.
      grep -q 'relocatable' $out || { echo "${band}: not a relocatable object" >&2; exit 1; }
      grep -q 'MIPS' $out || { echo "${band}: wrong architecture" >&2; exit 1; }
    '';

  # Attr names are band keys with the dot removed ("k2.6" -> "k26"), matching
  # boot.nix's bandKey. A literal "k2.6" attr is reachable only as
  # `-A '"k2.6"'`, since nix splits -A on '.'.
  checks = lib.listToAttrs (map
    (b: lib.nameValuePair (lib.replaceStrings [ "." ] [ "" ] b) (checkBand b))
    (builtins.attrNames bands));

in
checks // {
  all = pkgs.linkFarm "kernelsmith-module-checks"
    (lib.mapAttrsToList (n: v: { name = n; path = v; }) checks);
}
