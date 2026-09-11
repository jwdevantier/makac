<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Targets

A **target** is "somewhere I can run commands and read/write files". It is the
single abstraction through which actions touch a machine other than the one
makac runs on. The [Concepts: Targets](../concepts/targets.md) page explains the
model; this page is the precise API surface.

## Kinds

- **host** — the machine makac itself runs on. Always available as `makac.host`;
  used whenever a step/action does not name a target.
- **remote** — a machine reached over SSH, typically produced by an action
  (e.g. a VM-starting action returns its VM as `out.target`).

The kinds are fixed; actions produce targets of existing kinds, never new ones.

## Checking a value is a target

`makac.is_target(v)` returns true for any target — a table with `kind` `"host"`
or `"remote"` and `run`/`put`/`get`/`close` methods.

## The operations

Every target provides `run`, `put`, `get`, and `close` as methods.

### `run(argv, opts)` — execute a command

```lua
local res = target:run({ "cat", "/etc/resolv.conf" }, {
    chdir = "/tmp",         -- optional working directory
    env = { FOO = "bar" },  -- optional extra env, on top of the target's
    stdin = "data",         -- optional non-interactive stdin
    shell = "/bin/sh",      -- remote targets only: see the shell action's
                            -- `shell` argument (actions.md); defaults /bin/sh
    join = false,           -- optional: merge stderr into stdout (remote:
                            -- appends 2>&1 to the remote command line)
    -- timeout_s and on_line are host-only (unused on remote targets)
})
```

- `argv` is an array of strings: the program followed by its arguments. `argv[1]`
  must be a non-empty string; every element must be a string.
- Returns `{ code = int, stdout = string, stderr = string }`. (Host runs also
  surface `timed_out`; see `makac.exec` in [Lua standard library](lua-stdlib.md).)
- A **non-zero exit code is data, not an error** — it is returned in `code`. A
  *failed* `run` (target unreachable, program could not be started) raises.
- On a remote target, when `shell` or `env` is given, the command is wrapped as
  `shell -c "<env assignments> <quoted argv>"` and quoted again for the login
  shell; a `chdir` becomes `cd <dir> && <command>` (absent `chdir` defaults to
  the account's home directory, where ssh runs commands anyway).
- `timeout_s` and `on_line` are **not supported on remote targets** — passing
  them raises (for now).
- On a host target, `run` is exactly `makac.exec` (see the stdlib page): no
  shell involved, environment passed as a separate vector, `chdir` inherited
  from makac's own cwd when omitted.

### `put(src, dst)` — upload to the target

```lua
target:put("/host/path/or/dir", "relative/or/absolute/on/target")
```

Uploads a file or directory from the host onto the target. When `src` is a
directory, the transfer is recursive. A relative `dst` resolves against the
account's home directory (what `scp` does). Failure (missing src, transfer
error) raises.

### `get(src, dst)` — download from the target

```lua
target:get("/path/on/target", "/host/path")
```

Downloads a file or directory from the target to the host. Recursive for
directories; relative `src` resolves against the account's home directory.
Failure raises.

### `close()` — free the target

```lua
target:close()
```

- **Idempotent**: closing an already-closed target succeeds and does nothing.
- Frees the target's resources and tears down any session it held open (e.g.
  an SSH control master).
- After closing, `run`, `put` and `get` on the target **fail**.
- The runner closes every target when the workflow finishes — even on failure —
  so workflows rarely call this. An action may close a target early (e.g. an
  action that stops a VM closes the VM's target; later steps using it fail).

## Session reuse

A target stays usable across the steps that name it. Reaching a remote target
authenticates **once**; subsequent commands and file transfers multiplex over
that session rather than re-establishing it. Any working state a target needs
lives under the data directory (`<data_dir>/targets/<name>/`), separate per
target, so targets never interfere.

## Obtaining a target

- The **host** is always available: `makac.host`.
- A **remote** target usually comes from an action result:

```lua
local res = step {
    uses = "qemu:vm",
    with = { state = "started" },
}
local vm = res.out.target
```

- A workflow (or package) can construct targets itself:

```lua
-- an SSH-backed remote target (auth once, reused by later operations)
local t = makac.new_ssh_target("vm1", {
    host = "10.0.0.5",
    user = "root",
    -- port = 22,                 -- optional
    -- options = { IdentityFile = "..." },  -- optional extra ssh options
})

-- a target from a plain spec (makac wraps it with the lifecycle rules:
-- idempotent close, closed-target checks, method calling convention)
local t2 = makac.new_target {
    kind = "remote",
    name = "custom",
    run = function(argv, opts)
        return { code = 0, stdout = "", stderr = "" }
    end,
    put = function(src, dst) end,  -- optional; errors "not supported" if absent
    get = function(src, dst) end,  -- optional; same
    close = function() end,        -- optional teardown
}

-- advanced: a target from ops functions, used by package authors who need
-- the full lifecycle wrapper (kind/name must match make_target's contract)
local t3 = makac.make_target("remote", "name", {
    run = function(self, argv, opts) ... end,
    put = function(self, src, dst) ... end,
    get = function(self, src, dst) ... end,
    close = function(self) ... end,   -- optional
})
```

`makac.resolve_target(with)` resolves a step/action's `with` table to the
target it runs against: `with.target` when given (must be a real target), else
the host.

## Relationship to steps

- The `shell` action runs on `with.target` when one is given, else the host.
- Any other action may accept a target the same way; an action that documents a
  `target` parameter accepts the same values `shell` does — a real target
  object, or via the step's `target` shorthand.
