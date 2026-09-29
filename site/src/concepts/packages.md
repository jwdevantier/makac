<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Packages & the data directory

External actions are distributed as **packages** — bundles of Lua code and actions
that a project declares and fetches. Packages are what give makac its
GitHub-Actions-like pluggability: anyone can publish a package exposing actions,
and a workflow refers to them by their package alias.

## The data directory

makac keeps its per-project state in a data directory named **`.makac`**, local
to the project and residing in the project's root folder. It holds fetched
packages, caches, and per-target working state — everything makac generates or
fetches, so the whole directory can be gitignored. The project's package list is
the one exception: it is a hand-written file that lives beside the data
directory, in the project root.

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

### Initializing explicitly

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

## Declaring packages

Packages are declared in `makac_project.lua` in the project root, beside the
`.makac` data directory (not inside it). The file must return a table with two
keys: `inputs` (the fetch graph, keyed by local label) and `packages` (the
alias wiring):

```text
<project root>
  |- .makac/               (fetched + generated state; gitignored)
  |- makac_project.lua     (the project file; committed)
```

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

- **label** (the `inputs` key) — a local name for the fetch instruction.
  It names nothing in Lua-land; it appears in
  fetch/load messages. Two inputs may fetch two revs of the same package.
- **alias** (the `packages` key) — the project's local wiring name; it becomes
  the prefix used in workflows when referring to actions defined by this
  package: the action `hello` in a package wired as `qemu` is `qemu:hello`.
  Aliases may not contain `:` or `/`.
- **`fetcher`** — identifies how to fetch the input: a built-in fetcher name
  (`fetchurl`, `fetchgit`, `filesystem`), a fetcher provided by another package
  of the project (`qemu:fetchcvs` — see *Fetching order* below), or an inline
  `{ fetch = fn, key = ... }` object.
- **`with`** — optional argument table for the fetcher.

Fetching is **always explicit**: `makac fetch` downloads every input, and
`makac run` never fetches automatically. When you edit the file, you run
`makac fetch` again — no magic, no surprise network access during a run.

### Fetching order, storage, and pruning

`makac fetch` works through the inputs as a **worklist**: an input is fetched
as soon as its fetcher resolves in the registry, and every fetched package's
manifest `fetchers` immediately join the registry, so a package fetched earlier
in the run can provide the fetcher for a later input. A pass with no progress
is a hard error naming what each remaining input is waiting for (unwired
provider, typo, or a fetcher cycle).

Fetched packages are stored **content-addressed** under
`.makac/packages/<storage key>/`, where the key is produced by the fetcher's
`key` method (a pure hash of the semantically relevant `with` fields), and
`makac fetch` prunes any `packages/` entry no current input produced. Loading
recomputes the keys from the project file — a label resolves once its fetcher
is registered; a missing directory means "run `makac fetch`" (never-fetched or
edited-since-fetching). No recorded state: the data directory is derived
wholesale from the project file.

## Package layout

A package must have a **`makac_package.lua`** file (its *manifest*) at its
root, exporting the package's definitions:

```lua
-- makac_package.lua (at the package root)
return {
    -- the aliases this package expects the project to wire, each with a
    -- free-form message shown when the wiring is missing
    requires = { imglib = "qemu image helpers; get them from ..." },

    -- custom fetchers workflows can use, under '<alias>:<name>'
    fetchers = {
        fetchcvs = {
            key   = function(w) return "cvs-" .. makac.sha256("cvs\0" .. w.root) end,
            fetch = function(spec, dest) ... end,
        },
    },
    -- the package's actions
    actions = {
        hello  = function(with) ... end,
        reload = function(with) ... end,
    },
}
```

If the package contains a `./lib` directory, it is require-able under the key
`pkgs/<alias>`: to access `./lib/a.lua` in a package wired as `foo`, write
`require("pkgs/foo/a")`. This is how workflows (and packages) share helper
code with actions.

Inside a package, `require("./<mod>")` is a package-rooted relative import:
it resolves `<own package root>/lib/<mod>.lua` regardless of the alias a
consumer wired. Packages reference their own modules with `./`; workflows and
cross-package references use `pkgs/<alias>/...`.

A package may also ship a `health.lua` at its root: a check that
[`makac doctor`](../reference/doctor.md) runs to report the package's
prerequisites.

## Fetchers

makac provides three built-in fetchers:

| Fetcher | Purpose |
| --- | --- |
| `fetchurl` | Fetch a package over HTTP(S), verifying it against a SHA256 hash and uncompressing it. |
| `fetchgit` | Fetch a package from a Git repository; `rev` pins a commit, tag, or branch. |
| `filesystem` | Use a package from the local filesystem *in place* — the development fetcher. |

```lua
-- fetchurl
inputs = {
    somepkg = {
        fetcher = "fetchurl",
        with = {
            url = "https://example.com/some-file.tgz",
            sha256 = "...",       -- required; must match the fetched content
            unpacker = "tar",     -- required; or a custom uncompressor function
        },
    },
}

-- fetchgit
inputs = {
    somepkg = {
        fetcher = "fetchgit",
        with = {
            url = "https://github.com/user/some-repo.git",
            rev = "v1.2.0",       -- a commit hash, a tag, or a branch
        },
    },
}

-- filesystem: used in place, nothing is copied
inputs = {
    mypkg = {
        fetcher = "filesystem",
        with = {
            path = "path/to/package",  -- relative to the project root
        },
    },
}
```

Packages may provide additional fetchers; in a project file they are usable
as `<alias>:<name>` once the providing package is fetched in the same run
(the worklist above), and from workflows at run time.

See the [Fetchers reference](../reference/fetchers.md) for the full argument
tables.
