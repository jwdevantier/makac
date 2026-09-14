# Targets

A *target* is a place where makac can run commands and move files. It is the
single abstraction through which actions touch some machine other than the one
makac itself runs on — gathering information or causing state change.

A target should be understood as "somewhere I can run commands and read/write
files," not as any particular connection. Addresses, credentials and ports are
the target's own business; the action using it does not care.

## Kinds

Two kinds of target exist:

* **host** — the machine makac itself runs on. Always available. Used whenever
  a step does not name a target.
* **remote** — a machine reached over SSH. Typically obtained as the result of
  an earlier step (for example, an action that starts a VM returns a handle to
  that VM which can then be used as a target).

The set of kinds is fixed by makac itself; actions do not define new kinds —
they only produce targets of existing kinds.

## Operations

Every target supports exactly three operations:

### run

Execute a command on the target.

* The command is a list of words: the program followed by its arguments, e.g.
  `{"cat", "/etc/resolv.conf"}`.
* A working directory may be supplied. If omitted, the target's default is
  used: for the host, the directory makac was invoked from; for a remote
  target, the account's home directory.
* Additional environment variables may be supplied; these are set on top of
  the target's normal environment for the duration of the command.
* Input to the command (stdin) may be supplied as non-interactive data.
* The command's output is captured and returned together with its exit status.
  Output is held as two separate streams — stdout and stderr — with a joined
  view available for callers that want a single string (see below).

Importantly, a non-zero exit status is *data, not an error*. It is returned to
the action, which decides whether it matters (the `shell` action's
`ignore_exit_code` option is the most basic example of this decision). A
failed `run` means the command could not be executed at all — the target could
not be reached, or the program could not be started.

### Output separation

stdout and stderr are captured and returned separately; a single joined string
is optional and derived from the two, since joining is lossy.

No redirection on the target is needed to keep the streams apart: when a
command reaches makac over ssh, the transport carries stderr apart from stdout
and the local end receives them as two distinct streams. makac never merges
them itself. (This is exactly the separation that interactive terminal
handling — allocating a pty — would destroy, which is another reason
interactivity is out of scope.) If the command merges its own streams — e.g.
via `2>&1` — before they reach the transport, only the merged stream can be
observed. Because the two streams are drained independently, their order
relative to one another is not preserved.

### put

Upload a file or directory from the host onto the target.

Given a path on the host and a path on the target. When the source is a
directory, the transfer is recursive. A relative path on the target resolves
against the account's home directory (what scp does).

### get

Download a file or directory from the target to the host.

Given a path on the target and a path on the host. When the source is a
directory, the transfer is recursive. A relative path on the target resolves
against the account's home directory (what scp does).

## Naming

Every target has a name, used when reporting progress, e.g.:

```
[vm1] compiling test program...
[vm1] running test...
```

The host's name is something recognizable such as `host`.

## Obtaining a target

* The host target always exists and is used automatically whenever a step does
  not name one. It is globally available to workflows that want to refer to it
  explicitly.
* A remote target is obtained from an action's result, specifically `out.target`.
  For example, an action that starts a VM returns its target in
  `res.out.target`:

      local res = step {
        uses = "qemu:vm",
        with = { state = "started" },
      }
      local vm = res.out.target

  `vm` may then be passed to a later step's `target` field (or `with.target`),
  directing that step at the machine the earlier action stood up.

## Lifecycle

### Session reuse

Operations on a given target are not one-shot: a target stays usable across
the steps that name it. In particular, reaching a remote target authenticates
once; subsequent commands and file transfers reuse that session rather than
re-establishing it.

Any working state a target needs (for example, the state that lets it reuse a
session) lives under the makac data directory, separate per target, so two
targets never interfere.

### Closing

A target may be closed once it is no longer needed (`close`).

* Closing is **idempotent**: closing a target that is already closed succeeds
  and does nothing.
* Closing frees the target's resources and tears down any session it held
  open.
* After a target is closed, `run`, `put` and `get` on it are disallowed and
  fail.

The runner closes every target when the workflow finishes; individual steps
never have to do this themselves. An action may close a target earlier when it
makes sense — for example, an action that stops a VM closes the VM's target,
and any later step using that target fails.

## Relationship to steps

* `shell` is the simplest consumer: it runs its command on the host by default
  and on `with.target` when one is given (see `action_shell.md`).
* Any other action may accept a target the same way. An action that documents
  a `target` parameter accepts the same values `shell` does.

