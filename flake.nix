# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
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
      });
    };
}
