# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: CC0-1.0
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      allSystems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems = fn:
        nixpkgs.lib.genAttrs allSystems
          (system: fn {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ self.overlays.odin ];
            };
            inherit system;
          });
    in
    {
      overlays.odin = final: prev: {
        odin = prev.odin.overrideAttrs (finalAttrs: prevAttrs: {
          version = "dev-2026-06";
          src = prev.fetchFromGitHub {
            owner = "odin-lang";
            repo = "Odin";
            tag = finalAttrs.version;
            hash = "sha256-Z2497J80j5OLiyhTumrsofNANnNrnDE6Z3UB1b/TVGg=";
          };
          patches = [
            ./nix.patches/darwin-remove-impure-links.patch
          ];
        });

        ols = prev.ols.overrideAttrs (finalAttrs: prevAttrs: {
          version = "0-unstable-2026-06-21";
          src = prev.fetchFromGitHub {
            owner = "DanielGavin";
            repo = "ols";
            rev = "8b1c17f78a89936f248a0dd0c12d56bfa004cae6";
            hash = "sha256-zmaqPBcv/a5EhB4EbtpYdOGWbO/eLMcby630hbSEh+M=";
          };
        });
      };

      packages = forAllSystems ({ pkgs, ... }:
        let
          makac = pkgs.stdenv.mkDerivation {
            pname = "makac";
            # Keep in sync with vm/version.odin; the release workflow bumps it.
            version = "0.6";

            src = ./.;

            nativeBuildInputs = with pkgs; [ odin ];
            buildInputs = [ pkgs.lua5_4 ];

            buildPhase = ''
              runHook preBuild
              # Odin's bundled Lua 5.4 binding points at Odin's own archive
              # (linux/amd64) or at `system:lua5.4` (elsewhere). nixpkgs names
              # its library `liblua`, so shadow the binding with one that links
              # pkgs.lua5_4 on every platform. ODIN_ROOT is set with overwrite=0
              # by the Odin wrapper, so exporting our own wins.
              real_root="$(dirname "$(command -v odin)")/../share"
              root="$TMPDIR/odin-root"
              mkdir -p "$root/vendor/lua"
              ln -s "$real_root/base" "$real_root/core" "$real_root/shared" "$root/"
              for d in "$real_root"/vendor/*; do
                [ "$(basename "$d")" = lua ] && continue
                ln -s "$d" "$root/vendor/"
              done
              for d in "$real_root"/vendor/lua/*; do
                [ "$(basename "$d")" = 5.4 ] && continue
                ln -s "$d" "$root/vendor/lua/"
              done
              cp -r "$real_root/vendor/lua/5.4" "$root/vendor/lua/5.4"
              chmod -R u+w "$root/vendor/lua/5.4"
              substituteInPlace "$root/vendor/lua/5.4/lua.odin" \
                --replace-fail 'foreign import lib "linux/liblua54.a"' 'foreign import lib "system:lua"' \
                --replace-fail 'foreign import lib "system:lua5.4"'       'foreign import lib "system:lua"'
              export ODIN_ROOT="$root"
              # Bare file names keep embedded paths out of the closure.
              odin build . -out:makac -source-code-locations:filename
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 makac $out/bin/makac
              runHook postInstall
            '';

            meta = {
              description = "Orchestrator/runner with workflows written in Lua";
              homepage = "https://github.com/jwdevantier/makac";
              license = pkgs.lib.licenses.bsd2;
              mainProgram = "makac";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        in
        {
          inherit makac;
          default = makac;
        });

      devShells = forAllSystems ({ pkgs, ... }: {

        default = pkgs.mkShell {
          name = "odin-dev";

          packages = with pkgs; [
            odin
            ols

            gcc
            gnumake

            gdb
          ];

          # NOTE: Odin reads no library search env vars (LIBRARY_DIRS,
          # C_INCLUDE_DIRS, ...) itself; it shells out to clang, which links
          # any `foreign import lib "system:<name>"` as `-l<name>`. If a
          # system library is ever needed, wire it up the usual Nix way:
          #   LIBRARY_PATH/LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.<lib> ]

          shellHook = ''
            echo "Odin:  $(odin version)"
          '';
        };

        site = pkgs.mkShell {
          name = "makac-site";
          packages = [ pkgs.mdbook ];
        };
      });
    };
}
