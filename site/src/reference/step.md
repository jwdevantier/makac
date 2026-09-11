<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Step specification

`step { ... }` is the DSL surface for instantiating an action. It executes
**immediately** when evaluated, and returns the action's normalized result
table. The spec is a single Lua table:

```lua
local result = step {
    uses = "shell",        -- required: action reference
    name = "say hi",       -- optional: human-readable name
    with = { ... },        -- optional: action arguments, passed verbatim
    target = some_target,  -- optional: shorthand for with.target
}
```

## Fields

| Field | Required | Type | Meaning |
| --- | --- | --- | --- |
| `uses` | yes | string | The action reference: a built-in name (`shell`, `facts`) or `<pkg>:<action>` for an action from a fetched package. Must be a non-empty string. |
| `name` | no | string | Human-readable name used in progress reporting. Defaults to the action's registered default name (e.g. `"run shell command"` for `shell`, `"gather facts"` for `facts`), else to the `uses` string itself. An empty string behaves like an omitted name. |
| `with` | no | table | Argument table passed to the action **verbatim**. Its keys are action-specific (see [Built-in actions](actions.md)). |
| `target` | no | target | Shorthand for `with.target`: the step runs against this target. Must be a real target (e.g. `makac.host` or an action's `out.target`). Giving the target both here and in `with.target` is an error. |

There is no other spec surface: the workflow's own control flow (loops,
conditionals, functions) is the step's "engine", not a declarative field.

## Defaults recap

- **No `name`** → the action's registered default name, else `uses`.
- **No `target`** (and no `with.target`) → the host.
- **No `with`** → the action receives `nil` (actions must tolerate that).

## Return value

A step returns the action's result table, normalized so callers can rely on
this shape (see [Built-in actions](actions.md) for per-action `out` contents):

```lua
{
    err = nil,       -- string: set iff the action failed; absent otherwise
    changed = false, -- bool: true if the action changed system state
    skipped = false, -- bool: true if the action was skipped
    out = {},        -- table: action-specific return values
}
```

## Failure handling

A step fails when its action raises, or when the action's result sets `err`.
Either way the step aborts the workflow: makac prints a `failed:` progress line
for the step, then raises an error naming the step and the action:

```text
step 'doom' (uses 'shell') failed: command exited with code 1: ...
```

There is no `on_error` / continue-on-failure field: **a failed step always
aborts the run.** This is deliberate — a workflow is a Lua program, so if you
want conditional handling of a step's outcome, the step must *not* fail in the
first place: use the action's own data-as-failure options (e.g. `shell` with
`with.ignore_exit_code`, which leaves `err` unset and returns the exit code in
`out.code`), or inspect the result's fields and branch in Lua.

```lua
-- 'failure as data': the step cannot fail, you decide what the code means
local res = step {
    uses = "shell",
    with = {
        cmd = { "test", "-f", "flag.txt" },
        ignore_exit_code = true,
    },
}
if res.out.code == 0 then
    -- flag.txt exists
end
```

## Progress reporting

Every step reports twice on **stderr**: when it starts (`run: [<target>] <name>`)
and how it ended, Ansible-style, with status and elapsed time:

```text
run: [host] say hi
changed: [host] say hi (0.0s)
ok: [host] gather facts (0.1s)
skipped: [vm_mini] savevm mini-base (2.1s)
failed: [host] doomed (0.0s)
```

The status is `ok` (ran, unchanged), `changed`, `skipped`, or `failed`; the
`failed` line prints before the abort error above. Colors (green/yellow/cyan/red)
are environment-controlled: `MAKAC_COLOR=never` (or `0`/`false`/`no`/`off`)
disables them, `MAKAC_COLOR=always` (or `1`/`true`/`yes`/`on`) forces them on,
`NO_COLOR` (any value) disables them, and by default they are on unless `TERM`
is unset or `dumb`. stdout stays reserved for the workflow's own output.
