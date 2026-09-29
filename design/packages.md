The program provides a lua vm with the lua 5.4+ VM plus additional functionality exposed to the VM through functions implemented in Odin.

Also, the program shall provide a small set of built-in actions (see design/action.md).
Because actions are essentially implemented in Lua, it becomes possible to fetch and use externally defined actions. We will call
a bundle of lua code and actions a *package*.

The program shall provide a means of automating the fetching of external packages.
To this end, we create `makac_project.lua` in the project root, BESIDE the `.makac`
data directory rather than inside it (see design/data_directory.md for where that
directory is located). The data directory holds only fetched and generated state, so it
can be gitignored wholesale; the project file is a hand-written project file and belongs
in version control with the rest of the project:

```
<project root>
  |- .makac/                (data directory: fetched + generated state, gitignored)
  |- makac_project.lua      (the project file: committed)
  |- ...                    (the rest of the project)
```

makac creates `makac_project.lua` (empty wiring) whenever it creates the data directory, so a
freshly initialized project is ready to declare packages.

## The project file: labels and aliases

`makac_project.lua` must return a table with two keys:

- `inputs` — the fetch graph: a map from a local **label** to a fetch entry
  (`fetcher` + optional `with`; see design/fetchers.md).
- `packages` — the wiring: a map from an **alias** to an input label.

```lua
return {
  inputs = {
    -- the key is a local label for the fetch instruction
    qemu = {
      fetcher = "fetchgit",
      with = {
        url = "https://github.com/jwdevantier/qemu.makac",
        rev = "1c194ed",
      },
    },
  },
  -- the alias is the ONLY name workflows and packages use:
  -- 'qemu:img' in a step's uses field, require("pkgs/qemu/img") in Lua
  packages = { qemu = "qemu" },
}
```

Two names, two roles:

- The **label** identifies a fetch instruction (where to get code from). Local to the
  project file; it shows up in fetch/load messages. Two inputs
  may fetch two revs of the same package — labels keep them apart.
- The **alias** is the project's local wiring name for a fetched package. Registry
  keys are `<alias>:<name>` and lib requires are `pkgs/<alias>/<mod>`. Alias
  uniqueness is structural (table keys), so packages can never collide in the
  registries.

There are no canonical package names: a package never names itself, storage is
keyed purely by fetcher arguments, and identity questions ("is this really the
repo I meant?") are answered by the fetch arguments themselves, not by
self-declaration.

Storage is **content-addressed**: fetched code lands in
`.makac/packages/<storage key>/`, where the key comes from the fetcher's `key` method
(a pure hash of the semantically relevant `with` fields — e.g. url+rev for git).
`makac fetch` prunes any `packages/` entry no current input produced. Loading
recomputes keys from the inputs (the same worklist, minus materialization): a
label resolves once its fetcher exists; a missing directory means "run
`makac fetch`". There is no recorded state — the data directory is derived
wholesale from the project file.

Fetching uses a **worklist**: an input is fetched as soon as its fetcher resolves in
the registry; after each fetch the package's manifest runs and its `fetchers` join the
registry (under each alias wired to it) so a package fetched this run may fetch a
later input. A full pass without progress is a hard error naming, per remaining input,
what it is waiting for (unwired provider, typo, or a fetcher cycle).

## Package layout

A package must have a `makac_package.lua` file (its *manifest*) at its root, this is what
exports definitions out of the package and into makac proper:

```lua
return {
  -- the aliases this package expects the project to wire, each with a
  -- free-form message (where to get it, which version, ...). Load fails
  -- with this message if the alias is not wired. A flat membership check —
  -- no solving, no fetching, no version semantics.
  requires = { imglib = "qemu image helpers; get them from ... (v2 or later)" },

  fetchers = {
    -- a fetcher is an object: fetch(spec, dest) plus key(with), a pure hash
    -- of the semantically relevant args producing the storage key. Within a
    -- fetch run, a package fetched earlier may provide the fetcher for a
    -- later input ('other:input' in an entry's fetcher field).
    fetchcvs = {
      key = function(w) return "cvs-" .. makac.sha256("cvs\0" .. w.root) end,
      fetch = function(spec, dest) ... end,
    },
  },
  -- provide one or more new actions
  actions = {
    hello = ...,
    reload = ...,
  },
}
```

Exports are registered under the alias: `qemu:hello`, `qemu:reload`.

If the package contains a `./lib` dir, that directory is require-able under the key
`pkgs/<alias>`. To access `./lib/a.lua` of the package wired as `foo`, one writes
`require('pkgs/foo/a')`.

## Package-relative requires

Inside a package, `require("./<mod>")` is a *package-rooted relative import*: it
resolves `<own package root>/lib/<mod>.lua`, independent of whatever alias a consumer
wired for the package. This is how a package should reference its own modules
(`require("./img")`), instead of spelling out its own alias. Outside any package
(workflows, the project file) `./` imports are a hard error.

## Introspection

`makac.package_info(alias)` returns a read-only description of a wired package
(`{ alias, lib, actions, fetchers, requires }`) or `nil` — for optional,
enhance-if-available integrations. Hard needs belong in the manifest's `requires`,
where they are checked automatically at load.

## Style note: keep manifests declarative

A manifest's `requires` can only be known by *running* the manifest. If the
manifest body itself hard-requires a missing package's `pkgs/<alias>/...`, that
require fails before the `requires` check can print the author's message (the
error still names the missing alias and the fix). Keep manifests declarative —
return `requires` and export tables; put `require("pkgs/<dep>/...")` in
`lib/` modules or action bodies, both of which run after all packages are
loaded.
