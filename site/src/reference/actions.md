<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Built-in actions

makac ships two built-in actions. They are identified by a `uses` name without
any `:` — anything with a colon is a package action (`<pkg>:<action>`, see
[Packages & the data directory](../concepts/packages.md)).

Both actions return the normalized result shape described in the
[Concepts](../concepts/actions.md) chapter; this page documents the
action-specific inputs (`with`) and outputs (`out`).

## The result shape (recap)

```lua
{
    err = nil,       -- string, set iff the action failed; absent otherwise
    changed = false, -- bool
    skipped = false, -- bool
    out = {},        -- table: action-specific values
}
```

## `shell`

Runs a command on the host by default, or on a target when one is given. The
command is executed directly — no shell interpretation on the host — and its
output is captured as two separate streams.

### Inputs (`with`)

```lua
with = {
    -- required: the command as a list of words (program followed by args)
    cmd = { "cat", "/etc/resolv.conf" },

    -- optional: working directory. Host default: the directory makac was
    -- invoked from. Remote default: the account's home directory.
    chdir = "/tmp",

    -- optional: shell used to run the command on a REMOTE target;
    -- defaults to /bin/sh (see the note below). No effect on the host.
    shell = "/bin/sh",

    -- optional: additional environment variables, set on top of the target's
    -- normal environment for the duration of the command
    env = { THING = "true" },

    -- optional: data written to the command's stdin (non-interactive)
    stdin = "input data",

    -- optional, bool: merge stderr into stdout (the shell's `2>&1`),
    -- preserving true interleaved order; `out.stderr` then comes back empty.
    -- On remote targets this appends `2>&1` to the remote command line.
    join = false,

    -- optional, number (seconds): kill the command when it overruns
    -- (SIGTERM, a short grace, then SIGKILL); `out.timed_out` is set.
    -- Host only for now (not supported on remote targets).
    timeout_s = 30,

    -- optional, function(line, stream): called with each COMPLETE line as it
    -- arrives (stream is "stdout"/"stderr"); the full capture is still
    -- returned. A raising callback aborts the command and fails the step.
    -- Host only for now. Typical use: progress, e.g.
    --   io.stderr:write(line, "\n")
    on_line = nil,

    -- optional, bool: whether to avoid raising on a non-zero exit code.
    -- false by default: a non-zero exit sets `err` and fails the step.
    ignore_exit_code = false,
}
```

### Outputs (`out`)

```lua
out = {
    -- string: stdout, captured separately from stderr
    stdout = "",
    -- string: stderr
    stderr = "",
    -- string: stdout then stderr joined, for when a single string is more
    -- convenient (joining is lossy and optional; with join=true the stdout
    -- field itself holds the true interleaving)
    output = "",
    -- integer: the program's exit code
    code = 0,
    -- bool: true iff the command was killed by timeout_s
    timed_out = false,
}
```

`changed` is always `true` for a shell command (a conservative assumption).

### The `shell` argument

`shell` selects the shell used to run the command on a remote target. It
defaults to `/bin/sh`.

The argument exists because, over SSH, a command executes under the remote
user's *login* shell — which is arbitrary (fish, zsh, …) and need not be POSIX.
Setting environment variables relies on POSIX assignment syntax
(`NAME=value command ...`), which non-POSIX shells do not share. Rather than
depend on that, makac always invokes `shell` explicitly:

```text
shell -c "<env assignments> <argv>"
```

so the assignments are interpreted by a shell makac chose, deterministically
and independent of whatever the login shell happens to be.

On the host there is no login shell in the way — the command is spawned
directly with the environment passed as a separate vector — so `shell` has no
effect locally.

### Errors

- A command that cannot be executed at all (program not found, target
  unreachable) raises — the step fails.
- A non-zero exit code is **data**: it is returned in `out.code` and, unless
  `ignore_exit_code` is set, also reported as `err` (which fails the step).

## `facts`

Gathers host information via **fact finders** — small Lua functions that run
commands on a target and return a table. Unlike Ansible, facts are gathered
exactly when a `facts` step runs; there is no automatic pre-phase.

### Inputs (`with`)

```lua
with = {
    -- required: map namespace -> fact finder
    finders = {
        os  = "os",   -- a built-in finder by name
        env = "env",  -- another built-in
        -- or a function: a custom/imported finder
        -- custom = function(target) return { ... } end
    },

    -- optional: the target to gather from. Omitted: the host.
    -- target = vm,
}
```

A finder value is either a **string** naming a built-in finder or a
**function**. A finder runs on the given target and must return a table; a
finder that errors, or returns a non-table, fails the step.

### Outputs (`out`)

```lua
out = {
    -- each namespace becomes a table of the finder's return values
    facts = {
        os  = { os = "linux", arch = "x86_64" },  -- from the 'os' finder
        env = { PATH = "...", HOME = "...", ... }, -- from the 'env' finder
    },
}
```

`changed` is always `false` (gathering facts changes nothing).

### Built-in finders

| Finder | What it returns |
| --- | --- |
| `os` | `{ os = <string>, arch = <string> }` from `uname -s` / `uname -m` on the target. |
| `env` | The target's environment as a `NAME -> value` table (from `env`). |

See the [Concepts: Facts](../concepts/facts.md) page for examples of using
facts in a workflow.
