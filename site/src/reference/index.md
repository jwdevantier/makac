<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Reference

This chapter is the detailed, code-accurate reference for makac. Where the
[Concepts](../concepts/index.md) chapter explains *why*, this chapter documents
*exactly* — every field, default, argument, and return value.

| Page | What it documents |
| --- | --- |
| [CLI](cli.md) | The `makac` command-line interface: `init`, `run`, `fetch`, `--version`, and exit behavior. |
| [Step specification](step.md) | The `step { ... }` spec: fields, defaults, and failure handling. |
| [Built-in actions](actions.md) | The `shell` and `facts` actions: their `with` inputs and result `out` shapes. |
| [Targets](target.md) | The target abstraction: `run`, `put`, `get`, session reuse, and closing. |
| [Fetchers](fetchers.md) | The fetcher mechanism for packages: the three built-in fetchers and their arguments. |
| [Lua standard library](lua-stdlib.md) | The `makac.*` primitives exposed to workflows, beyond plain Lua 5.4. |

Everything here was verified against makac's source (the Lua prelude and the
Odin VM bindings), so where a design note and the code disagree, the code wins.
