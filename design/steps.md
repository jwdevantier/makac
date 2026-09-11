# Steps

- a `step` is a concrete instantiation of an action
- it is the equivalent of a GitHub Actions *step*, or of an Ansible *task*
  (an action plays the role of an Ansible *module*)
- `step { ... }` executes **immediately** when it is evaluated
- a workflow is evaluated from line 1 onwards, top to bottom
- since a step runs the moment it is evaluated, steps may sit inside plain Lua
  control flow — loops, conditionals, functions — so the workflow decides which
  steps run, when, and how often
  - deferring execution would cut us off from that

## Step spec

- `uses` (required): action reference — a built-in name (`shell`, `facts`) or
  `<pkg>:<action>` for an action from a fetched package
- `name` (optional): human-readable step name; defaults to the action's
  registered default name, else the `uses` string itself
- `with` (optional): argument table passed to the action verbatim
- `target` (optional): shorthand for `with.target`

## Result and failure handling

A step reports twice on stderr (the host target name stands in when the
step names no target): when it STARTS, and how it ENDED — Ansible-style,
with the result's `changed`/`skipped`/`err` flags mapping to statuses and
wall-clock elapsed time included:

    run: [host] build bootbase (cloud-init) image
    changed: [host] build bootbase (cloud-init) image (41.3s)
    ok: [host] image raw-1 (0.0s)
    skipped: [vm_mini] savevm mini-base (2.1s)
    failed: [host] doomed (0.0s)

Statuses: `ok` (ran, unchanged) / `changed` / `skipped` / `failed` — the
`failed` line prints BEFORE the abort error (below), so the failing step
is unmissable even mid-log. Colors follow the usual conventions (green /
yellow / cyan / red, bold `run` headers) and are controlled by
environment, no flags:

- `MAKAC_COLOR=never` (or `0`/`false`/`no`/`off`) — colors OFF;
- `MAKAC_COLOR=always` (or `1`/`true`/`yes`/`on`) — colors ON, even if
  `TERM` says dumb;
- `NO_COLOR` (any value, per no-color.org) — colors OFF;
- default — ON unless `TERM` is unset or `dumb`.

All reporting goes to stderr; stdout stays reserved for the workflow's own
output.

A step returns the action's result table, normalized to always have the
shape of design/action.md.

If the action raises, or its result sets `err`, the step aborts the workflow
with an error naming the step and the action — a failing step never goes
unnoticed. Actions that treat failure as data (e.g. `shell` with
`ignore_exit_code`) simply do not set `err`.