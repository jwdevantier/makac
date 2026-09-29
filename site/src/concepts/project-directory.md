<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Project directory

A makac project is an ordinary directory that holds two makac-owned items: the
hand-written **project file** `makac_project.lua`, and the **data directory**
`.makac/`. Everything else is your own code.

```text
<project root>/
  |- makac_project.lua   the project file (committed): inputs + alias wiring
  |- .luarc.json         generated: points your editor's LuaLS at the data directory
  `- .makac/             the data directory (gitignored): all fetched + generated state
       |- packages/      fetched packages, content-addressed (after `makac fetch`)
       |- pkgs/          editor aliases -> each package's lib/ (LuaLS)
       `- makac.lua      generated LuaLS stub for makac's API
```

## The project file

`makac_project.lua` is hand-written and belongs in version control. It must
return a table with two keys: `inputs` (the fetch graph) and `packages` (the
alias wiring):

```lua
-- makac_project.lua
return {
    inputs = {
        -- the key is a local label for the fetch instruction
        qemu = {
            fetcher = "fetchgit",
            with = {
                url = "https://github.com/jwdevantier/makac.qemu",
                rev = "1c194ed",
            },
        },
    },
    packages = { qemu = "qemu" },
}
```

- **label** (the `inputs` key) — a local name for the fetch instruction; it
  names nothing in Lua-land and appears only in fetch/load messages. Two inputs
  may fetch two revs of the same package.
- **alias** (the `packages` key) — the project's local wiring name; it becomes
  the prefix used in workflows when referring to actions defined by this
  package: the action `hello` in a package wired as `qemu` is `qemu:hello`.
  Aliases may not contain `:` or `/`.
- **`fetcher`** — how to fetch the input; see [Fetchers](../reference/fetchers.md).
- **`with`** — optional argument table for the fetcher.

The file is wiring only: writing it never fetches anything. See
[Packages](packages.md) for fetching it and using the result.

## The data directory

`.makac/` holds everything makac generates or fetches — fetched packages,
caches, per-target working state, and the generated LuaLS files — so the whole
directory can be gitignored. The hand-written `makac_project.lua` is the one
exception, and lives beside it in the project root.

When makac is invoked, it looks for the data directory like so:

1. look in the current directory for `.makac`; if not found, continue
2. look in the current directory for `.git`; if not found, continue
3. look in the parent directory, and loop back to step 1

Two special cases:

- If a `.git` folder is found but no `.makac` folder, makac **creates** the
  `.makac` directory there — and, beside it, an empty `makac_project.lua` — so
  it just sets the project up for you.
- If neither is found all the way to the filesystem root, makac errors out and
  tells you to initialize the data directory yourself.

## Initializing a project

`makac init <path>` creates a data directory:

- if `<path>` ends with `.makac`, it is used exactly as given;
- otherwise, makac creates `<path>/.makac`.

Either way it also creates an empty `makac_project.lua` beside the data
directory (unless one already exists), so you can start declaring packages right
away.

```bash
makac init myproject
makac: initialized data directory at myproject
```
