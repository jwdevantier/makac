<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Getting Started

This page walks you through building makac from source and running your first workflow.
You need nothing but the Odin compiler to build; on Nix, everything comes from the flake.

## Build from source

Clone the repository and enter the default development shell:

```bash
git clone https://github.com/jwdevantier/makac
cd makac
nix develop
```

`nix develop` drops you into the project's dev shell, which provides the Odin compiler
(and the usual build tools). If you are not using Nix, install the Odin compiler yourself
and skip straight to the build.

Then, from the repository root, build the binary:

```bash
odin build . -out:makac
```

The resulting executable is `./makac` at the repository root. It is gitignored, so it
will never end up in a commit — rebuild whenever you pull changes.

> **Note:** the `site` dev shell (`nix develop .#site`) exists for working on this
> documentation itself; it provides `mdbook` instead of the Odin toolchain.

## A first tour

### 1. Initialize a data directory

makac keeps its per-project state in a data directory named `.makac`. Every makac
command that touches a project resolves it by walking up from your current directory
until it finds a `.makac` or `.git` directory (creating `.makac` at the first `.git` it
finds). It is usually easiest to create it explicitly:

```bash
makac init myproject
makac: initialized data directory at myproject
```

This creates `myproject/.makac`. If the path you pass ends in `.makac`, makac uses it
verbatim; otherwise it appends `/.makac`.

### 2. Write a workflow

Workflows are Lua files. Let's create `myproject/hello.lua`:

```lua
step {
    name = "say hello",
    uses = "shell",
    with = {
        cmd = { "echo", "hello from makac" },
    },
}
```

A `step` is a concrete instantiation of an action. Here the built-in `shell` action runs
`with.cmd` (an array of arguments, executed directly — no shell interpolation) on the
runner. The `name` is optional and shows up in makac's progress reporting.

### 3. Run it

From inside `myproject`, run the workflow:

```bash
cd myproject
makac run hello.lua
```

`makac run` evaluates the file top to bottom, executing each `step` the moment it is
reached — which is what allows steps to sit inside ordinary Lua control flow (loops,
conditionals, functions). Every step is reported to **stderr** as it starts and when it
finishes, Ansible-style, with status and elapsed time:

```text
run: [host] say hello
changed: [host] say hello (0.0s)
```

The statuses are `ok` (ran, unchanged), `changed`, `skipped`, and `failed`. A step that
fails aborts the workflow immediately with an error naming the step and the action — a
failed step never goes unnoticed. Output of the workflow itself stays on **stdout**.

### 4. Fetch packages

makac does not resolve dependencies on its own. Packages are declared in
`.makac/packages.lua` inside the data directory, and fetched explicitly with
`makac fetch`:

```lua
-- .makac/packages.lua
return {
    {
        id = "qemu",             -- referenced as 'qemu:<action>' in workflows
        fetcher = "fetchgit",    -- built-ins: fetchurl, fetchgit, filesystem
        with = {
            url = "https://github.com/jwdevantier/makac.qemu.git",
            rev = "main",
        },
    },
}
```

```bash
makac fetch
```

The file must be a Lua file that returns an array of package entries. Each entry has an
`id` (used to reference the package's actions, e.g. `qemu:vm`), a `fetcher` (a built-in
fetcher name, or a function), and an optional `with` table of fetcher arguments. Fetching
is always explicit — `makac run` never fetches automatically, so you control exactly when
dependencies are updated. See [Fetchers](reference/fetchers.md) for the details.

### 5. Check your environment

makac can report whether the programs it and your packages depend on are
available:

```bash
makac doctor
```

It prints one group per package (plus a `makac` group for makac itself), with
`OK` / `INFO` / `WARN` / `ERROR` lines, and exits non-zero if anything is
wrong. See [Doctor](reference/doctor.md).

## Next steps

- Read [Concepts](concepts/index.md) to understand workflows, steps, actions, targets,
  and facts.
- Follow [Examples](examples/index.md) for complete, runnable workflows — including the
  QEMU + NVMe loop that motivated makac.
