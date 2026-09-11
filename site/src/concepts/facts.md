<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Facts

**Facts** are host information gathered by the built-in `facts` action — an
action like any other, instantiated with `step { uses = "facts", ... }`.

## Unlike Ansible, gathering is your choice

In Ansible, gathering facts is an obligatory phase that runs at the start of a
play. makac deliberately does not work that way:

- **You choose *when* to collect facts.** There is no automatic pre-phase; a
  workflow gathers facts exactly when a `facts` step runs — and any later step
  may have changed the system in ways that alter the facts.
- **You choose *which* finders to run**, and how many in one go. Run only the
  finders you need, when you need them.

## Fact finders

A **fact finder** is a small Lua function that:

- takes a target,
- runs commands on that target to determine some information,
- returns an associative table of whatever it wants to expose.

Its signature is `function (target) return {...} end`.

The `facts` action is given an associative table mapping a **namespace** to a
finder:

```lua
local facts = step {
    name = "Gather system facts",
    uses = "facts",
    with = {
        finders = {
            os  = "os",   -- a built-in finder, referred to by name
            env = "env",  -- another built-in
        },
        -- optional: the target to gather from.
        --   omitted, facts are gathered on the runner (host) itself.
        -- target = vm1,
    },
}
```

Each namespace becomes a table under the result: `facts.out.facts.<namespace>`.
For the example above, `facts.out.facts.os` and `facts.out.facts.env`.

A finder value is either:

- a **string** naming a built-in finder, or
- a **function** — a custom finder, for example one imported from a package's
  `lib/` directory (`require("pkgs:<id>/...")`, see
  [Packages & the data directory](packages.md)).

## Built-in finders

makac ships with two built-in finders:

| Finder | What it returns |
| --- | --- |
| `os` | Operating system and architecture of the target, from `uname -s` and `uname -m`: `{ os = "linux", arch = "x86_64" }`. |
| `env` | The target's environment variables, as a `NAME -> value` table (from `env`). |

## Using facts in a workflow

Because a step returns its result, gathered facts are just a Lua value the rest
of the workflow can branch on:

```lua
local facts = step {
    uses = "facts",
    with = {
        finders = { os = "os" },
    },
}

if facts.out.facts.os.arch == "x86_64" then
    step {
        uses = "shell",
        with = {
            cmd = { "echo", "building for x86_64" },
        },
    }
end
```

The `facts` action never changes system state, so its result reports
`changed = false`.

Writing your own finders is covered in the
[Built-in actions reference](../reference/actions.md); the built-in finders are
also listed there.
