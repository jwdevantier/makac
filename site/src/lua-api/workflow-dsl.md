<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# The workflow DSL

These are defined by the embedded Lua prelude, which runs once before any
user-facing Lua. This is the surface workflows (and package/action authors) are
written against; it builds on the primitives in the [Makac API](makac-api.md).

## `step { ... }`

Instantiates an action and runs it immediately. Full spec in
[Step specification](../reference/step.md).

## Targets

| Primitive | Description |
| --- | --- |
| `makac.host` | The host target (machine makac runs on). Always available. |
| `makac.is_target(v)` | Returns true if `v` is a target (table with `kind` `"host"`/`"remote"` and `run`/`put`/`get`/`close` methods). |
| `makac.resolve_target(with)` | Resolves a `with` table to the target it runs against: `with.target` when given, else `makac.host`. |
| `makac.make_target(kind, name, ops)` | Constructs a target from ops functions `{ run(self, argv, opts), put(self, src, dst), get(self, src, dst), close(self) }`, wrapping them with the lifecycle rules (idempotent close, closed-target checks). Kinds are fixed: `"host"`/`"remote"`. |
| `makac.new_target(spec)` | Constructs a target from a plain spec `{ kind, name, run(argv, opts) -> {code, stdout, stderr}, put?, get?, close? }`; missing `put`/`get` raise "not supported". |
| `makac.new_ssh_target(name, spec)` | An SSH-backed remote target: `{ host, user, port?, options? }`. Auth happens once; later ops multiplex. |
| `makac.close_all_targets()` | Closes every live target (reverse order, best-effort). Called by `makac run` after the workflow, even on failure. |

Target operations (`run`/`put`/`get`/`close`) are documented on the
[Targets](../reference/target.md) reference page.

## Registries (for package/action authors)

| Primitive | Description |
| --- | --- |
| `makac.define_action(name, fn, opts)` | Registers action `name`; `fn(with)` returns a result table (normalized by `run_action`). `opts.default_name` is used by `step` when a step omits `name`. Redefining an action is an error. |
| `makac.run_action(uses, with)` | Resolves `uses` in the registry, invokes it with `with`, normalizes and returns the result. Unknown actions raise; a raising action is wrapped with an error naming the action. |
| `makac.normalize_result(res)` | Fills in the result defaults: `changed=false`, `skipped=false`, `out={}`. `err` is left as-is (absent unless set). |
| `makac.register_fetcher(name, fn)` | Registers a fetcher (see [Fetchers](../reference/fetchers.md)). |
| `makac.register_fact_finder(name, fn)` | Registers a fact finder for the `facts` action (see [Built-in actions](../reference/actions.md)). |

## Package loading (used by the CLI, usable in workflows)

| Primitive | Description |
| --- | --- |
| `makac.data_dir` | The VM's data directory (may be the empty string for a data-dir-less VM). |
| `makac.project_root(data_dir?)` | The project root: the directory that holds the data directory (and `makac_project.lua`). |
| `makac.project_file_path(data_dir?)` | Path of the project file: `<project root>/makac_project.lua`. |
| `makac.pkg_dirs` | Maps each wired package's alias to its code root on disk. |
| `makac.read_project_file(data_dir?)` | Reads and validates the project's `makac_project.lua` (beside the data directory), returning `inputs, aliases, labels`. |
| `makac.resolve_fetcher(def)` | Resolves an entry's `fetcher` to its fetch callable (string name → registry lookup; an inline object contributes its `fetch`). |
| `makac.resolve_pkg_dir(def, data_dir?)` | Where an input entry's code lives: `<data_dir>/packages/<storage key>/` recomputed from the entry (nil when the fetcher isn't registered yet — deferrable), or `with.path` for a `filesystem` package. |
| `makac.fetch_all(data_dir?)` | Worklist-fetches every input into `<data_dir>/packages/<storage key>/`, merging each fetched package's `fetchers` for later inputs; prunes stale entries at the end. |
| `makac.load_packages(data_dir?)` | Loads every wired package's `makac_package.lua` into the registries under `<alias>:<name>`, resolving aliases in a fetch-mirroring worklist (missing directories → "run makac fetch"), then checks every manifest's `requires` against the wired aliases. No `makac_project.lua` → returns 0. |
| `makac.package_info(alias)` | Read-only description of a wired package (`{ alias, lib, actions, fetchers, requires }`) or `nil`; never fetches or loads anything. |

Package-provided `lib/` code is require-able as `require("pkgs/<alias>/a/b")` via a
searcher the prelude installs (maps to `<package root>/lib/a/b.lua`). Inside a
package, `require("./a")` resolves `<own package root>/lib/a.lua` regardless of
the alias a consumer wired (a `./` import outside any package is a hard error).

## Scoped cleanup

`makac.defer(fn)` and `makac.errdefer(fn)` return a Lua 5.4 to-be-closed value;
declare it with `<close>` and Lua runs `fn` when the enclosing block exits —
`defer` on any exit, `errdefer` only when the block exits via an error:

```lua
local guard <close> = makac.errdefer(function() release_thing() end)
```

Both are best-effort: an error from `fn` is reported on stderr, never raised,
so cleanup cannot mask the error being unwound. The `<close>` is load-bearing —
a plain local is not closed.
