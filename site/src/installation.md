<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Installation

There are three ways to get `makac`:

- **[Nix flake](#nix-flake)** — Nix users, and the only option that runs
  out of the box on NixOS.
- **[Prebuilt binary](#prebuilt-binary)** — most Linux users; no toolchain
  needed.
- **[Build from source](#build-from-source)** — development, or a platform
  with no release binary.

## Nix flake

The flake exposes the package as `packages.<system>.makac` (and `default`).

Run it without installing anything:

```bash
nix run github:jwdevantier/makac -- --version
```

Or drop into a shell that has `makac` on `PATH`:

```bash
nix shell github:jwdevantier/makac#makac
```

Pin a revision by putting it in the ref:

```bash
nix shell github:jwdevantier/makac/23eae10#makac
```

To use it from your own flake, add `makac` as an input and take the package
from `makac.packages.<system>`:

```nix
{
  inputs.makac.url = "github:jwdevantier/makac";

  outputs = { self, nixpkgs, makac }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # in a development shell …
      devShells.${system}.default = pkgs.mkShell {
        packages = [ makac.packages.${system}.default ];
      };

      # … or installed for the whole system
      # environment.systemPackages = [ makac.packages.${system}.default ];
    };
}
```

Or install it into your profile:

```bash
nix profile install github:jwdevantier/makac
```

## Prebuilt binary

Each release publishes binaries for Linux amd64 and arm64 on the
[releases page](https://github.com/jwdevantier/makac/releases), together with
their checksums:

```
makac-linux-amd64
makac-linux-arm64
makac-linux-amd64.sha256
makac-linux-arm64.sha256
```

Download the one matching your machine, verify it, and put it on your `PATH`:

```bash
curl -fsSLO https://github.com/jwdevantier/makac/releases/latest/download/makac-linux-amd64
curl -fsSLO https://github.com/jwdevantier/makac/releases/latest/download/makac-linux-amd64.sha256
sha256sum -c makac-linux-amd64.sha256
install -m755 makac-linux-amd64 ~/.local/bin/makac
```

The binaries are built on AlmaLinux 9 (glibc 2.34) with Lua statically linked
in, and are dynamically linked only against the C library. They run on any
glibc-based distribution from the last few years — RHEL 9, Ubuntu 22.04,
Debian 12, and newer. On NixOS the generic binary will not start as-is; use
the [Nix flake](#nix-flake) instead (or `nix-ld`).

## Build from source

Building needs the [Odin compiler](https://odin-lang.org/) and a C
compiler/linker. Clone the repository and build:

```bash
git clone https://github.com/jwdevantier/makac
cd makac
odin build . -out:makac
```

With Nix you do not install Odin yourself; the dev shell provides it:

```bash
git clone https://github.com/jwdevantier/makac
cd makac
nix develop
odin build . -out:makac
```

The result is `./makac` in the repository root. It is gitignored, so it never
ends up in a commit — rebuild whenever you pull changes. Put it on your `PATH`,
or run it in place.

> **Note:** `nix develop .#site` is a separate shell for working on this
> documentation; it provides `mdbook` instead of the Odin toolchain.

Once you have a binary, continue to [Getting Started](getting-started.md) for
your first workflow.
