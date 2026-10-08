<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Lua API

Workflows are evaluated in a **Lua 5.4** VM. Everything in the
[Lua 5.4 standard library](https://www.lua.org/manual/5.4/#index) is available,
plus two layers of makac-specific API:

- [Makac API](makac-api.md) — the host API baked into the VM: the `makac.*`
  primitives (`makac.exec`, `makac.fs.*`, `makac.time.*`, `makac.env.*`,
  processes, downloads, JSON, …) and the script-context globals (`arg`,
  `SCRIPT_DIR`, `PROJECT_DIR`).
- [The workflow DSL](workflow-dsl.md) — the prelude-defined surface workflows are
  written against: `step`, targets, the registry helpers, and package loading.

The embedded prelude is evaluated once, before any user-facing Lua, so every
workflow sees everything below. `makac` may already hold the host-side primitives
before the prelude runs; the prelude only extends it.

## Editor support (LuaCATS / lua-language-server)

So an editor can type a workflow, makac installs a small stub and points
lua-language-server at it. Whenever the data directory is created or refreshed
(`makac init`, `makac run`, `makac fetch`) it writes:

- `<data_dir>/makac.lua` — LuaCATS definitions for `makac`, `step`, and the
  surface documented here;
- `<data_dir>/pkgs/<alias>` — one symlink per wired package, so
  `require("pkgs/<alias>/...")` resolves to the package's `lib/`;
- `.luarc.json` at the project root, whose `workspace.library` names the data
  directory as the single library root.

Open the project in an editor using lua-language-server and `makac`/`step` (and
package modules) resolve. No package is ever written to; a `.luarc.jsonc`, if
present, shadows `.luarc.json` and is left alone.
