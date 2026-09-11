<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Steps

A **step** is a concrete instantiation of an action — the equivalent of a GitHub
Actions *step* or an Ansible *task* (an action plays the role of a GitHub Actions
*action* or an Ansible *module*). You create one with a call to `step { ... }`.

## Steps run when evaluated

`step { ... }` executes **immediately** when it is evaluated — it never defers.
Since a workflow is evaluated top to bottom, a step at the top of the file runs
before a step further down. Because execution is immediate, steps may sit inside
plain Lua control flow: a step in a loop runs once per iteration, a step in a
conditional runs only when the branch is taken, and a step inside a function runs
when the function is called (see [Workflows](workflows.md)).

## The step spec

`step` takes a single table:

```lua
local result = step {
    -- required: which action to instantiate.
    --   a built-in name:         "shell", "facts"
    --   a package action:        "<pkg>:<action>", e.g. "qemu:vm"
    uses = "shell",

    -- optional: human-readable name, shown in progress reporting.
    --   defaults to the action's registered default name, else the `uses` string.
    name = "do a thing",

    -- optional: argument table, passed to the action verbatim.
    --   the keys vary by action; see the action's documentation.
    with = {
        cmd = { "echo", "hi" },
    },

    -- optional: shorthand for with.target — a target to run against.
    --   omitted, the step runs on the host (see targets.md).
    --   given both here and in with.target, makac errors.
    target = some_vm,
}
```

- **`uses`** (required): the action reference. A name without `:` is a built-in
  action; `<pkg>:<action>` refers to an action from a fetched package (see
  [Packages & the data directory](packages.md)).
- **`name`** (optional): used in progress reporting. If omitted, the action's
  registered default name is used; as a last resort, the `uses` string itself.
- **`with`** (optional): the argument table handed to the action verbatim. Its
  contents are action-specific — `shell` takes `cmd`, `env`, `chdir`, and more;
  `facts` takes `finders` (see [Actions](actions.md) and [Facts](facts.md)).
- **`target`** (optional): shorthand for `with.target`. If neither is given, the
  step runs on the host.

## What a step returns

A step returns the action's result table, normalized so that callers can always
rely on this shape:

```lua
{
    err = nil,       -- string: set iff the action failed; absent otherwise
    changed = false, -- bool: true if the action changed system state
    skipped = false, -- bool: true if the action was skipped
    out = {},        -- table: action-specific return values, e.g. out.stdout
}
```

Actions may put anything they like in `out` — the `shell` action returns
`out.stdout`, `out.stderr`, `out.code`, etc.; a VM action returns the VM in
`out.target`. See [Actions](actions.md) for the full picture.

## Progress reporting

Every step reports twice on **stderr**: when it starts, and how it ended,
Ansible-style, with the step's status and elapsed wall-clock time. The target the
step ran against is shown in brackets (the host's name stands in when the step
names no target):

```text
run: [host] do a thing
changed: [host] do a thing (0.0s)
ok: [host] image bootbase (41.3s)
skipped: [vm_mini] savevm mini-base (2.1s)
failed: [host] doomed (0.0s)
```

The statuses are `ok` (ran, unchanged), `changed`, `skipped`, and `failed`.
Colors follow the usual conventions (green / yellow / cyan / red) and are
controlled by the environment, with no flags: `MAKAC_COLOR=never` (or `0`,
`false`, `no`, `off`) turns colors off; `MAKAC_COLOR=always` turns them on even
when `TERM` says `dumb`; `NO_COLOR` (any value, per [no-color.org](https://no-color.org))
turns them off; by default colors are on unless `TERM` is unset or `dumb`.

All reporting goes to stderr; **stdout stays reserved for the workflow's own
output**, so piping the workflow's output works without makac's progress getting
in the way.

## Failure handling

A failing step never goes unnoticed. If the action raises, or its result sets
`err`, the step aborts the workflow with an error naming the step and the action:

```text
step 'doom' (uses 'shell') failed: command exited with code 1: ...
```

Actions that treat failure as data — e.g. `shell` with `ignore_exit_code` — do
not set `err`, and their steps continue normally. See [Actions](actions.md) for
how actions signal success and failure, and the
[Step specification](../reference/step.md) reference page for the exact field
table.
