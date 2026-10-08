<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Installation

There are three ways to get `makac`:

- **[Nix flake](#nix-flake)** — Nix users, and the most convenient option on
  NixOS.
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
nix shell github:jwdevantier/makac/<commit hash>#makac
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

Each release publishes binaries for Linux x86_64 and aarch64 on the
[releases page](https://github.com/jwdevantier/makac/releases), together with
their checksums:

```
makac-linux-x86_64-musl
makac-linux-aarch64-musl
makac-linux-x86_64-musl.sha256
makac-linux-aarch64-musl.sha256
```

Download the one matching your machine, verify it, and put it on your `PATH`:

```bash
curl -fsSLO https://github.com/jwdevantier/makac/releases/latest/download/makac-linux-x86_64-musl
curl -fsSLO https://github.com/jwdevantier/makac/releases/latest/download/makac-linux-x86_64-musl.sha256
sha256sum -c makac-linux-x86_64-musl.sha256
install -m755 makac-linux-x86_64-musl ~/.local/bin/makac
```

The binaries are statically linked against musl, so they have no runtime
loader or shared-library dependency and run on any Linux distribution,
NixOS included. They still need the tools makac shells out to at runtime
(`ssh`, `scp`, `curl`, `git`, `tar`); `makac doctor` checks for them.

## Build from source

Building needs the [Zig compiler](https://ziglang.org/) (0.16.0). Zig supplies
the C compiler and linker, so nothing else is required. Clone the repository
and build:

```bash
git clone https://github.com/jwdevantier/makac
cd makac
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

With Nix you do not install Zig yourself; the dev shell provides it:

```bash
git clone https://github.com/jwdevantier/makac
cd makac
nix develop
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

`-Doptimize=ReleaseSafe` is the optimized build the release binaries are made
with; `--prefix ~/.local` installs the result as `~/.local/bin/makac`, so make
sure that directory is on your `PATH`. Zig's build cache is gitignored, so
nothing ends up in a commit — rebuild whenever you pull changes.

> **Note:** `nix develop .#site` is a separate shell for working on this
> documentation; it provides `mdbook` instead of the Zig toolchain.

Once you have a binary, continue to [Getting Started](getting-started.md) for
your first workflow.
