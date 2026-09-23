<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Packages & the data directory

External actions are distributed as **packages** — bundles of Lua code and actions
that a project declares and fetches. Packages are what give makac its
GitHub-Actions-like pluggability: anyone can publish a package exposing actions,
and a workflow refers to them by their package id.

## The data directory

makac keeps its per-project state in a data directory named **`.makac`**, local
to the project and residing in the project's root folder. It holds the package
list (`packages.lua`), fetched packages, and per-target working state.

When makac is invoked, it looks for the data directory like so:

1. look in the current directory for `.makac`; if not found, continue
2. look in the current directory for `.git`; if not found, continue
3. look in the parent directory, and loop back to step 1

Two special cases:

- If a `.git` folder is found but no `.makac` folder, makac **creates** the
  `.makac` directory there — it can determine where your project root is, so it
  just sets the data directory up for you.
- If neither is found all the way to the filesystem root, makac errors out and
  tells you to initialize the data directory yourself.

### Initializing explicitly

`makac init <path>` creates a data directory:

- if `<path>` ends with `.makac`, it is used exactly as given;
- otherwise, makac creates `<path>/.makac`.

```bash
makac init myproject
makac: initialized data directory at myproject
```

## Declaring packages

Packages are declared in `.makac/packages.lua` inside the data directory. The
file must return an array-like table whose elements are tables with at least
`id` and `fetcher` keys:

```lua
-- .makac/packages.lua
-- elements are fetched in the order given; earlier packages may provide
-- specialized fetchers for fetching later packages
return {
    {
        id = "qemu",   -- referenced in workflows as 'qemu:<action>'
        fetcher = "fetchgit",
        with = {
            url = "https://github.com/jwdevantier/makac.qemu",
            rev = "1c194ed",
        },
    },
}
```

- **`id`** — becomes the prefix used in workflows when referring to actions
  defined by this package: the action `hello` in a package with id `qemu` is
  `qemu:hello`. Ids may not contain `:` (the separator).
- **`fetcher`** — identifies how to fetch the package: a built-in fetcher name
  (`fetchurl`, `fetchgit`, `filesystem`), or a fetcher contributed by an earlier
  package (`mypkg:fetchcvs`), or a function.
- **`with`** — optional argument table for the fetcher.

Fetching is **always explicit**: `makac fetch` downloads every package in the
list, in order, and `makac run` never fetches automatically. When you update the
list, you run `makac fetch` again — no magic, no surprise network access during
a run.

## Package layout

A package must have a **`makac.lua`** file at its root, exporting the package's
definitions:

```lua
-- makac.lua (at the package root)
return {
    -- custom fetchers other packages can use
    fetchers = {
        fetchcvs = function(args, destdir) ... end,
    },
    -- the package's actions
    actions = {
        hello  = function(with) ... end,
        reload = function(with) ... end,
    },
}
```

If the package contains a `./lib` directory, it is added to the package loader
under the key `pkgs/<id>`: to access `./lib/a.lua` in a package with id `foo`,
write `require("pkgs/foo/a")`. This is how workflows (and packages) share helper
code with actions.

## Fetchers

makac provides three built-in fetchers:

| Fetcher | Purpose |
| --- | --- |
| `fetchurl` | Fetch a package over HTTP(S), verifying it against a SHA256 hash and uncompressing it. |
| `fetchgit` | Fetch a package from a Git repository; `rev` pins a commit, tag, or branch. |
| `filesystem` | Use a package from the local filesystem *in place* — the development fetcher. |

```lua
-- fetchurl
{
    id = "somepkg",
    fetcher = "fetchurl",
    with = {
        url = "https://example.com/some-file.tgz",
        sha256 = "...",       -- required; must match the fetched content
        unpacker = "tar",     -- required; or a custom uncompressor function
    },
}

-- fetchgit
{
    id = "somepkg",
    fetcher = "fetchgit",
    with = {
        url = "https://github.com/user/some-repo.git",
        rev = "v1.2.0",       -- a commit hash, a tag, or a branch
    },
}

-- filesystem: used in place, nothing is copied
{
    id = "mypkg.dev",
    fetcher = "filesystem",
    with = {
        path = "path/to/package",  -- relative to the project root
    },
}
```

Packages may provide additional fetchers; to use one, prefix the exported
fetcher with the id of the package that provides it, e.g. `mypkg:fetchcvs`.

See the [Fetchers reference](../reference/fetchers.md) for the full argument
tables.
