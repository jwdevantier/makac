<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Targets

A **target** is a place where makac can run commands and move files. It is the
single abstraction through which actions touch some machine other than the one
makac itself runs on — gathering information or causing state change.

A target should be understood as *"somewhere I can run commands and read/write
files"*, not as any particular connection. Addresses, credentials and ports are
the target's own business; the action using it does not care.

## Kinds

Two kinds of target exist:

- **host** — the machine makac itself runs on. Always available. Used whenever a
  step does not name a target.
- **remote** — a machine reached over SSH. Typically obtained as the result of an
  earlier step (for example, an action that starts a VM returns a handle to that
  VM which can then be used as a target).

The set of kinds is fixed by makac itself; actions do not define new kinds — they
only *produce* targets of existing kinds.

## Operations

Every target supports exactly three operations:

### run — execute a command

```lua
local res = target:run({ "cat", "/etc/resolv.conf" }, {
    chdir = "/tmp",       -- optional working directory
    env = { FOO = "bar" },-- optional extra environment
    stdin = "data",       -- optional non-interactive stdin
})
-- res = { code = 0, stdout = "...", stderr = "..." }
```

The command is a list of words: the program followed by its arguments. A working
directory may be supplied (defaults: the directory makac was invoked from for the
host, the account's home directory for a remote target). Output is captured as
two separate streams — stdout and stderr — together with the exit status.

Importantly, a **non-zero exit status is data, not an error**. It is returned to
the action, which decides whether it matters (the `shell` action's
`ignore_exit_code` option is the most basic example). A *failed* `run` means the
command could not be executed at all — the target could not be reached, or the
program could not be started.

### put — upload to the target

```lua
target:put("/host/path/or/dir", "relative/or/absolute/on/target")
```

Uploads a file or directory from the host onto the target. When the source is a
directory, the transfer is recursive. A relative path on the target resolves
against the account's home directory (what `scp` does).

### get — download from the target

```lua
target:get("/path/on/target", "/host/path")
```

Downloads a file or directory from the target to the host. When the source is a
directory, the transfer is recursive. A relative path on the target resolves
against the account's home directory.

## Naming

Every target has a name, used when reporting progress:

```text
[vm1] compiling test program...
[vm1] running test...
```

The host's name is something recognizable such as `host`.

## Obtaining a target

- The **host** target always exists and is used automatically whenever a step
  does not name one. It is globally available to workflows that want to refer to
  it explicitly (as `makac.host`).
- A **remote** target is obtained from an action's result — specifically
  `out.target`:

```lua
local res = step {
    uses = "qemu:vm",
    with = { state = "started" },
}
local vm = res.out.target  -- a remote target, usable in later steps
```

The resulting target may then be passed to a later step's `target` field (or
`with.target`), directing that step at the machine the earlier action stood up:

```lua
step {
    uses = "shell",
    target = vm,
    with = {
        cmd = { "uname", "-a" },
    },
}
```

## Lifecycle

### Session reuse

Operations on a given target are not one-shot: a target stays usable across the
steps that name it. In particular, reaching a remote target authenticates once;
subsequent commands and file transfers reuse that session (SSH connection
multiplexing) rather than re-establishing it. Any working state a target needs
lives under the makac data directory, separate per target, so two targets never
interfere.

### Closing

A target may be closed once it is no longer needed:

- Closing is **idempotent** — closing an already-closed target succeeds and does
  nothing.
- Closing frees the target's resources and tears down any session it held open.
- After a target is closed, `run`, `put` and `get` on it fail.

The runner closes **every** target when the workflow finishes — even when the
workflow failed — so individual steps never have to do this themselves. An action
may close a target earlier when it makes sense: for example, an action that stops
a VM closes the VM's target, and any later step using that target fails.

## Relationship to steps

- `shell` is the simplest consumer: it runs its command on the host by default,
  and on `with.target` when one is given.
- Any other action may accept a target the same way. An action that documents a
  `target` parameter accepts the same values `shell` does — a real target object,
  or via the step's `target` shorthand.

See the [Targets reference](../reference/target.md) for the full API surface,
including how workflows can construct their own targets.
