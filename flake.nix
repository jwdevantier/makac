# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: CC0-1.0
{
  inputs = {
    # nixos-26.05 ships Zig 0.16.0
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = fn:
        nixpkgs.lib.genAttrs allSystems
          (system: fn {
            pkgs = import nixpkgs { inherit system; };
            inherit system;
          });
    in
    {
      # The installable other projects consume, e.g.
      #
      #   inputs.makac.url = "github:jwdevantier/makac.zig";
      #   makac = makac.packages.${system}.makac;
      #
      # (nvme-check wires exactly this under the `makac` package.)
      packages = forAllSystems ({ pkgs, ... }:
        let
          lib = pkgs.lib;

          # The version lives in src/version.zig; parse it so the package can
          # never drift from what `makac --version` reports.
          version =
            let
              m = builtins.match ".*pub const version = \"([0-9]+\\.[0-9]+)\";.*"
                (builtins.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ./src/version.zig));
            in
            if m == null then "0.0.0" else builtins.head m;

          # Only what an offline `zig build` needs: the build script, the
          # manifest, and src/ (whose prelude.lua and luals/makac.lua are
          # symlinks into the repo root, so include those targets too). Keeps
          # the heavy build/cache dirs and .ralphish out of the store.
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./prelude.lua
              ./luals
            ];
          };

          makac = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "makac";
            inherit version src;

            # The Zig setup hook supplies configure/build/check/install phases
            # (`zig build`, `zig build test`, `zig build install --prefix $out`)
            # and defaults to ReleaseSafe + `-Dcpu=baseline`.
            nativeBuildInputs = [ pkgs.zig ];

            # build.zig.zon fetches Lua from lua.org; the Nix sandbox has no
            # network. Nix's `zig.fetchDeps` pre-fetches the package cache in a
            # fixed-output derivation, and `postConfigure` drops it into Zig's
            # global cache so the real build stays offline.
            deps = pkgs.zig.fetchDeps {
              inherit (finalAttrs) src pname version;
              fetchAll = true;
              hash = "sha256-xIlAq8X3rm5l9kaBsdnsF0h8DFlmV+8zO8IlRskto8I=";
            };

            postConfigure = ''
              cp -rLT ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
              chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            # Run the module-level unit battery as the package's check phase.
            doCheck = true;

            meta = {
              description = "Orchestrator/runner with workflows written in Lua";
              homepage = "https://github.com/jwdevantier/makac";
              license = pkgs.lib.licenses.bsd2;
              mainProgram = "makac";
              platforms = pkgs.lib.platforms.unix;
            };
          });
        in
        {
          inherit makac;
          default = makac;
        });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          name = "zig-dev";
          packages = with pkgs; [
            zig
            zls           # Zig language server: editor go-to-definition/hover
          ];
          shellHook = ''
            echo "Zig: $(zig version)"
            echo "zls: $(zls --version)"
          '';
        };

        # Test harness tooling: the black-box/API/integration suites. openssh
        # provides the real sshd (ssh_real suite, auto-detected); python3 the
        # QMP dummy server; git the local fetchgit fixtures.
        testing = pkgs.mkShell {
          name = "makac-testing";
          packages = with pkgs; [
            openssh
            python3
            git
            curl
          ];
          shellHook = ''
            echo "sshd:   $(sshd -V 2>&1 | head -1 || echo missing)"
            echo "python: $(python3 --version)"
            echo "git:    $(git --version)"
          '';
        };

        # mdBook toolchain for the documentation site in ./site
        # (`mdbook serve` inside site/ for a live preview).
        site = pkgs.mkShell {
          name = "makac-site";
          packages = [ pkgs.mdbook ];
        };

        # REUSE license-compliance tooling:
        #   nix develop .#lint --command reuse lint
        lint = pkgs.mkShell {
          name = "makac-lint";
          packages = [ pkgs.reuse ];
        };
      });
    };
}
