# LuaCATS / LuaLS support

*Status: done.*

makac's Lua API is two things a language server cannot see on its own:

* **injected globals** — `makac` and `step` are pushed into the VM by the
  binary (`prelude.lua`, Odin `register`); there is no module to `require`,
  so LuaLS reports them as undefined;
* **package library code** — a package's `lib/` is required as
  `pkgs/<id>/<rel>` (design/packages.md). LuaLS cannot run the VM's
  `pkgs_searcher`; it only maps a `require` string to a path, so it looks for
  `<library root>/pkgs/<id>/<rel>.lua`.

`.makac` is normally gitignored and LuaLS honours `.gitignore`, so nothing
under it is seen unless it is named in `workspace.library`.

## One tree, one root

The VM has a loader; LuaLS does not — it only does static path lookup. They
agree if (and only if) the on-disk tree matches the require strings. So the
install is shaped to match, and nothing is aliased across roots:

```
<project>/.luarc.json             workspace.library = ["./<data>"]      ONE root
<project>/<data>/makac.lua        base stub: makac, step, Target, fs, ...
<project>/<data>/pkgs/<id>  ->    <package root>/lib                    (require alias)
```

The data directory **is** the one library root. Its `pkgs/<id>` alias sits
next to the code it points at, so LuaLS resolves the symlink to a single file
and indexes it **once**. (Listing a second root that reaches the same file is
what produced duplicate definitions.) The VM's loader maps
`pkgs/<id>/<rel>` to the same place.

A `filesystem`-fetcher package's code lives *outside* `<data>`, so its alias
points out of the root. That is fine: the alias is still the single path
under the root, the file is indexed once, and LuaLS follows it when the
package's own source is opened.

## Base stub

The stub is source at `luals/makac.lua` (`---@meta`) and is embedded in the
binary with `#load`, exactly like `prelude.lua` — the types always match the
running version, with no separate artifact to install or pin. It is exposed
to Lua as `makac.luals_stub` (`vm/luals.odin`) and written to the project as
`<data>/makac.lua`.

## Installation rules

`makac.luals_setup()` (prelude) runs after package loading on `makac run`
(and via `makac lsp`). It is **idempotent** and **best-effort**: it never
fails a workflow; a problem is a warning on stderr, and a broken install only
costs editor features, never a run.

* `<data>/pkgs/` is created as needed; one alias per loaded package
  (`makac.pkg_dirs`), replacing a stale link.
* `<data>/makac.lua` is written only when its content differs from the
  embedded stub, atomically (temp + rename) so a concurrent LSP never reads a
  half-file.
* `<project>/.luarc.json`'s `workspace.library` is **set to the single root**
  `./<data>`. makac owns that key; every other key is preserved. A
  `.luarc.jsonc` shadows `.luarc.json`; makac will not rewrite a file it
  cannot safely parse (JSON with comments) and prints what to add instead.
* the old `<data>/luals` tree (stub + mirror) is removed once, so it cannot be
  indexed as a second alias.

`makac lsp` is the same install without a workflow, for a project that has
none to run yet.

## Non-goals

* No stubs for third-party libraries: annotate their source in place (the
  same alias then picks them up).
* No per-package config or stub: a package is never written to.
* Not a `require`-able module: `makac` stays an injected global; the stub
  only teaches the editor about it.
* Runtime is untouched — this is editor tooling only.
