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
