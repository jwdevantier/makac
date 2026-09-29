<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Packages

External actions are distributed as **packages** — bundles of Lua code and actions
that a project declares and fetches. Packages are what give makac its
GitHub-Actions-like pluggability: anyone can publish a package exposing actions,
and a workflow refers to them by their package alias.

## Using packages

Declare what you need in your project's
[`makac_project.lua`](project-directory.md) and wire it to an alias:

```lua
return {
    inputs = {
        qemu = {
            fetcher = "fetchgit",
            with = { url = "https://github.com/jwdevantier/makac.qemu", rev = "1c194ed" },
        },
    },
    packages = { qemu = "qemu" },   -- alias -> input label
}
```

- **`inputs`** say *where code comes from*: one entry per thing to fetch, each
  naming a **fetcher** and its arguments. The built-ins are `fetchurl`,
  `fetchgit` and `filesystem`; the [Fetchers reference](../reference/fetchers.md)
  documents them and their argument tables. Packages may also provide
  *additional* fetchers, so one input's fetcher can be supplied by another
  package.
- **`packages`** says *what to call it*: a map from an **alias** to an input
  **label**. The alias is the only name workflows and packages use.

Then download everything with `makac fetch`. Fetching is **never** automatic:
`makac run` will not fetch, so run `makac fetch` whenever you add or change a
dependency.

[`makac doctor`](../reference/doctor.md) checks the wiring: a package can
declare a dependency it needs (`requires = { alias = "message" }`), and doctor
reports every one that the project has not wired — one line apiece, with the
package author's message. It is the fastest way to see why a package complains
about a missing dependency.

Dependency resolution is **yours**, not makac's. The approach is somewhat
inspired by Nix flakes: `inputs` are the fetch graph, the alias wiring is the
override layer, and `.makac/packages/` is the store — but there is no lockfile
and no solver. Every input pins its own source
(`rev`, `sha256`, …), storage is content-addressed and recomputed from
`makac_project.lua`, and you curate the set.

The indirection buys you easy substitution: because names and sources are
separate, you can fork a package, swap one implementation for another, or wire
two revisions of the same package side by side without touching the packages'
own code. It is deliberately smaller than a full package manager — makac gives
you the fetch graph, the wiring, and the store, and leaves resolution to you.

Once wired, an alias is available everywhere:

- `uses = "qemu:vm"` in a step;
- `require("pkgs/qemu/img")` from Lua.

### Fetching order

`makac fetch` works through the inputs as a **worklist**: an input is fetched
as soon as its fetcher resolves, and every fetched package's `fetchers`
immediately join the registry — so one package can provide the fetcher used to
fetch another (e.g. `fetcher = "qemu:fetchcvs"`). A pass with no progress is a
hard error naming what each remaining input is waiting for.

Fetched packages are stored content-addressed under `.makac/packages/<key>/`,
keyed by a hash of the fetcher's arguments; stale entries are pruned at the end
of a fetch, and loading recomputes the keys — a missing directory means "run
`makac fetch`" (never-fetched, or edited since fetching).

## Defining a package

A package must have a **`makac_package.lua`** file (its *manifest*) at its
root, exporting the package's definitions:

```text
<package root>/
  |- makac_package.lua    the manifest: actions, fetchers, requires
  |- health.lua           optional: checks run by `makac doctor`
  `- lib/                 optional: modules, require-able as pkgs/<alias>/...
       |- a.lua
       `- b.lua
```

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
