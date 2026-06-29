{
  description = "musl-cross-make cross toolchains (gcc-era x arch matrix) for the rehosting kernel/driver build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    # Pin musl-cross-make; flake=false so we drive its Makefile ourselves.
    musl-cross-make = {
      url = "github:richfelker/musl-cross-make";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, musl-cross-make }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      sources = import ./sources.nix { inherit pkgs; };
      matrix = import ./matrix.nix { inherit lib; };
      resolve = import ./resolve.nix { inherit lib; };

      mkCrossToolchain = import ./mk-cross-toolchain.nix {
        inherit pkgs sources;
        mcmSrc = musl-cross-make;
      };

      # Primary sourcing path for k3/k4/k6: vendored Bootlin prebuilt toolchains.
      mkBootlinToolchain = import ./mk-bootlin-toolchain.nix { inherit pkgs; };
      bootlinSources = import ./bootlin-sources.nix { inherit pkgs; };
      bootlinToolchains = lib.mapAttrs
        (name: s: mkBootlinToolchain { inherit name; inherit (s) tarball target crossAlias; })
        bootlinSources;

      # Build one toolchain for an (era, arch) cell.
      cell = eraName: era: archName: arch:
        mkCrossToolchain ({
          name = "${archName}-${eraName}";
          inherit (arch) target;
          inherit (era) gccVer binutilsVer muslVer gmpVer mpcVer mpfrVer linuxVer;
          extraConfig = arch.extraConfig or [ ];
        });

      # Cartesian product era x arch (musl-cross-make), minus unsupported pairs.
      # Keyed "<era>-<arch>". Most of these are the FALLBACK path (placeholder
      # hashes for now); Bootlin cells below override the ones we've vendored.
      mcmToolchains = lib.listToAttrs (lib.flatten (lib.mapAttrsToList
        (eraName: era:
          lib.mapAttrsToList
            (archName: arch:
              let key = "${eraName}.${archName}";
              in lib.optional (!(builtins.elem key matrix.unsupported)) {
                name = "${eraName}-${archName}";
                value = cell eraName era archName arch;
              })
            matrix.arches)
        matrix.eras));

      # Canonical toolchain set: vendored Bootlin where pinned, musl-cross-make
      # otherwise. Both keyed "<era>-<arch>", so Bootlin simply overrides.
      toolchains = mcmToolchains // bootlinToolchains;

      # The unified entrypoint: (version, arch, src, config) -> kernel, with the
      # toolchain auto-resolved from the version. This is the "move between
      # kernel versions as targets" function.
      buildKernel = import ./kernel.nix { inherit pkgs toolchains resolve; };

      # Resolve a toolchain straight from a kernel version + arch, for callers
      # (igloo_driver module builds, ad-hoc shells) that just want the compiler.
      toolchainFor = version: arch: toolchains.${resolve.toolchainKey version arch};
    in
    {
      inherit buildKernel toolchainFor;

      packages.${system} = toolchains // {
        # Every pinned Bootlin cell (k3/k4/k6 × covered arches) — all buildable now.
        bootlin-all = pkgs.linkFarm "bootlin-all"
          (lib.mapAttrsToList (n: v: { name = n; path = v; }) bootlinToolchains);

        # The from-source spike: the hard case (ancient gcc 4.x, k2.6) — the one
        # genuinely risky build left. Placeholder hashes until tackled.
        spike = mcmToolchains."k2.6-armel";

        default = self.packages.${system}."k6-mipseb";
      };

      # The single environment. `nix develop` here drops you into a shell where
      # every toolchain is resolvable on demand. `kbuild <version> <arch>`
      # resolves the era, realizes (or substitutes from cache) just that
      # toolchain, and puts its cross prefix on PATH — so you flip between
      # kernel versions as targets without rebuilding anything you've seen.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ gnumake bc bison flex openssl elfutils nix ];
        shellHook = ''
          kbuild() {
            local ver="$1" arch="$2"
            [ -n "$ver" ] && [ -n "$arch" ] || { echo "usage: kbuild <kernel-version> <arch>"; return 1; }
            local tc
            tc=$(nix build --no-link --print-out-paths --impure --expr \
                  "(builtins.getFlake \"$PWD\").toolchainFor \"$ver\" \"$arch\"" 2>/dev/null) || {
              echo "no toolchain for $ver/$arch"; return 1; }
            export PATH="$tc/bin:$PATH"
            echo "resolved $ver/$arch -> $tc"
          }
          echo "rehosting toolchain env: use 'kbuild <version> <arch>' (e.g. kbuild 3.18.140 mipsel)"
        '';
      };
    };
}
