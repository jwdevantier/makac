<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Actions

An **action** is a unit of work that a step instantiates. Actions are inspired by
Ansible: they describe a desired end-state rather than an operation to perform —
declarative rather than imperative. The `shell` action, for example, does not say
"run this command"; it says "make it so that this command was run" (and reports
whether it *changed* anything).

The step is the only way an action runs — actions are never invoked directly by a
workflow, only through `step { uses = ..., with = ... }`. See
[Steps](steps.md) for the step spec.

## How actions are implemented

Actions are implemented in **Lua** and run on the host — the machine makac itself
runs on. When an action needs to gather information from, or cause state change
on, another machine, it does so through the **target** abstraction: running shell
commands on the target, or moving files to/from it (see [Targets](targets.md)).
The Lua code drives the decision-making; the target is just the interface to a
remote machine.

## The result shape

Every action returns a result table. makac normalizes it, filling in defaults, so
a step's caller can always rely on this shape:

```lua
{
    err = nil,       -- string: set iff the action failed; describes what went
                     --         wrong (absent otherwise — failure is never
                     --         reported via the other keys)
    changed = false, -- bool: true if the action changed system state
    skipped = false, -- bool: true iff the action was skipped
    out = {},        -- table: action-specific return values, varies by action
}
```

- `err` is the only failure channel. An action that "fails" as part of normal
  operation — e.g. a command that exits non-zero, when the action opts to treat
  that as data — leaves `err` unset.
- `out` holds whatever the action wants to give back: `shell` returns the
  captured `stdout`/`stderr`/`code`; an action that starts a VM returns the VM as
  `out.target`.

## Naming actions

An action is referenced by name in a step's `uses`. Names without a `:` are the
built-in actions. External actions come from packages and are referenced as
`<package id>:<action name>` — the part before the `:` is the package id, the
part after is the action name. A package id can therefore never contain `:`
itself (see [Packages & the data directory](packages.md)).

## Built-in actions

A small subset of actions is built into makac. They are identified by not
containing any `:` character:

| Action | Purpose |
| --- | --- |
| `shell` | Run a command on the host (or on a target), capturing output and exit code. |
| `facts` | Gather host information via fact finders. See [Facts](facts.md). |

Both are documented in detail in the [Reference](../reference/actions.md)
chapter; their concepts are covered on this chapter's pages.

## Where actions come from

- **Built-in** — `shell` and `facts`, always available.
- **Packages** — a bundle of Lua code and actions fetched from elsewhere,
  exposing actions under its id (e.g. `qemu:vm`, `qemu:img`). Packages can also
  provide custom fetchers, used to fetch *other* packages. See
  [Packages & the data directory](packages.md).

Because actions are Lua, a package's actions are ordinary Lua functions wrapped
by `makac.define_action` — anything a package can do, a workflow could in
principle do directly; packages just make it shareable and versioned.
