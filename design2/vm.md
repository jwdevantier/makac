# The `qemu:vm` action

`qemu:vm` is the action through which a VM is brought into a desired state:
started, stopped, or restarted.

```lua
local vm = step {
  name = "start test VM",
  uses = "qemu:vm",
  with = {
    name  = "testvm",                  -- required: VM identity (see handle.md)
    state = "started",                 -- "started" (default) | "stopped" | "restarted"

    -- required for state = "started"/"restarted":
    qemu_bin = "/usr/bin/qemu-system-x86_64",
    args = {                           -- QEMU command line, as an argv array
      "-nodefaults",
      "-machine", "q35,accel=kvm,kernel-irqchip=split",
      "-m", "4096",
      "-netdev", "user,id=net0,hostfwd=tcp::2222-:22",
      -- ...
    },

    -- optional: ssh configuration for out.target (see below)
    ssh = {
      port = 2222,   -- the host-assigned port; connects to 127.0.0.1:port
      -- all ssh keys have defaults (see "SSH defaults" below):
      user = "root",
      identity_file = "~/.ssh/id_ed25519",
      options = { StrictHostKeyChecking = "no" },   -- extra ssh -o options
    },

    -- optional: boot disk as a throwaway overlay (see "Overlay boot disks")
    disk = {
      backing = img.out.path,   -- base image (e.g. a qemu:img result); never written
    },

    -- optional; only meaningful when ssh is configured (default: wait):
    wait_ssh = { timeout_s = 120, interval_s = 2 },
    -- wait_ssh = false,               -- return as soon as QEMU is launched
  },
}
```

## `args`: an argv array

`args` is the QEMU command line in argv form: each element is one word,
passed verbatim. Elements are never split. Comma-joined QEMU property
strings are ordinary strings (`"-machine", "q35,accel=kvm"`).

Elements may be nested arrays or functions; all are flattened before launch,
so configuration composes:

```lua
local function boot_disk(device)
  return {
    "-drive", "id=bdrv.boot,file=" .. device .. ",format=qcow2,if=none",
    { "-device", "nvme-ns,id=ns.boot,drive=bdrv.boot,nsid=1,bus=nvme-ctrl.1" },
    function() return { "-boot", "order=c" } end,   -- may decide conditionally
  }
end
```

Flattening rules: strings pass through; list-like tables flatten depth-first;
functions are called (no arguments) and their return flattens recursively;
`nil`/`false` elements drop; anything else is a spec error naming its path.

Associative tables serialize to QEMU property strings — one word:

```lua
{ "-machine", { type = "q35", accel = "kvm", ["kernel-irqchip"] = "split" } }
-- one word: "accel=kvm,kernel-irqchip=split,type=q35"

{ "-netdev", { user = true, id = "net0", hostfwd = "tcp::2222-:22" } }
-- one word: "hostfwd=tcp::2222-:22,id=net0,user"
```

Serialization is **canonical**: keys sort lexically, `k=v` pairs join with
`,`, a `true` value is the bare flag, strings/numbers pass as-is; anything
else is a spec error. Two tables with the same entries serialize identically
regardless of construction order (Lua `pairs` order never leaks out).
List-like structure, in contrast, keeps its order: argv order is meaning in
QEMU, so differently-ordered words are different invocations.

## Auto-injected runtime arguments

On start, the package appends:

```
-pidfile   <run_dir>/pid
-monitor   unix:<run_dir>/monitor.socket,server,nowait
-serial    file:<run_dir>/serial
-qmp       unix:<run_dir>/qmp.socket,server,nowait
```

These are infrastructure: the pidfile and sockets are what makes handles,
status probes, `qemu:qmp/send` and stop possible; the serial file captures
the console (below).

Supplying `-pidfile`, `-monitor`, `-serial` or `-qmp` in `args` is a spec
error naming the conflicting word.

## Start semantics (`state = "started"`)

1. Create the runtime directory; truncate the previous run's
   `qemu-stdout.log`/`qemu-stderr.log`.
2. Probe (handle.md). If the VM is already running:
   * *same invocation* — the canonical invocation (below) matches. No-op:
     return the handle, `changed = false`.
   * *different invocation* — spec failure. Changing a running VM's command
     line is spelled `state = "restarted"`.
3. Otherwise launch QEMU, detached, stdout/stderr redirected to the log
   files. The QEMU process is not a child makac waits on. A launch that
   exits immediately (bad args, missing image) is a step failure quoting the
   qemu-stderr log.
4. Open the VM's QMP connection on `<run_dir>/qmp.socket` and attach it to
   the handle — this is the connection every qmp action against the VM will
   use (qmp.md, handle.md). A socket that never appears within a short
   launch window is a step failure: QEMU is up but not controllable.
5. If `ssh` is configured and `wait_ssh` isn't `false`, poll ssh until a
   trivial command runs, up to `timeout_s`; timeout is a step failure naming
   the serial log.

Return:

```lua
{
  changed = true,
  out = {
    handle = <handle table>,
    target = <makac remote target> or nil,   -- iff ssh configured
    pid    = 1234,
    -- ... plus the handle.md status fields
  },
}
```

## Invocation identity

Whether an already-running VM counts as "the same VM" is decided by
comparing **invocations**, and an invocation is exactly what the workflow
author wrote — `qemu_bin` and `args` — and nothing the package adds. The
auto-injected runtime arguments (pidfile, sockets, serial log) derive from
`name`+`run_dir` and are constant for a given identity; they are not part
of the comparison.

Concretely:

* An invocation's **canonical form** is `qemu_bin` (as given) followed by
  the flattened `args`, with associative tables serialized canonically as
  defined above. Canonicalization happens *after* flattening, so syntactic
  variation in how the list was composed — nesting, functions, table build
  order — collapses to the same form.
* At start, the canonical form is written verbatim to
  `<run_dir>/invocation`. It is text, not a hash, so a "different
  invocation" failure can show the diff.
* Same invocation = byte-identical canonical form. There is no semantic
  equivalence: `-m 4G` and `-m 4096` are different invocations.
* A VM that is running but has no `<run_dir>/invocation` (started outside
  `qemu:vm`, or state dir tampered with) has unknowable identity: the step
  fails — "VM 'x' is running but has no recorded invocation; stop it first."

## Stop semantics (`state = "stopped"`)

Probe first.

* Not running → remove stale runtime files, `changed = false`.
* Running → graceful first: QMP `system_powerdown`; poll `query-status`
  every 1s until the process exits or `timeout_s` (default 20) elapses.
  Then, when `force` (default true), force: QMP `quit`, then `kill -9` to
  the pidfile pid. On success, close the handle's QMP connection, remove
  runtime files, return `changed = true`.

`state = "restarted"` is stop followed by start, unconditionally.

## Overlay boot disks

A VM's boot disk is usually a built image (`qemu:img`, images.md) — an
artifact meant to be reused, not consumed by boots. `with.disk` expresses
that separation:

```lua
disk = { backing = img.out.path }
```

Semantics:

* On start, the package creates a qcow2 overlay at `<run_dir>/disk.qcow2`
  backed by `backing`:
  `qemu-img create -f qcow2 -b <backing> -F qcow2 <run_dir>/disk.qcow2`.
  The backing image is never written to.
* `args` refers to the overlay via the substitution `{{ disk }}`:
  `{"-drive", "id=bdrv.boot,file={{ disk }},format=qcow2,if=none"}`.
  (`{{ disk }}` is the only substitution available in VM args; it is a spec
  error when no `disk` is given.)
* `state = "restarted"` (stop + start) recreates the overlay: every fresh
  start of the VM name boots a pristine disk. **Exception: `qemu:loadvm`**
  (snapshots.md). A snapshot saved from an overlay-booted VM lives *in* the
  overlay; recreating it would destroy the snapshot. A restart that resumes
  from a snapshot therefore keeps the existing overlay.
* The canonical invocation includes `backing`'s absolute path, not its
  content: a rebuilt image at the same path does not invalidate a running
  VM — its overlay still points at the old file. Booting onto the rebuilt
  image is spelled `state = "restarted"`.
* Without `disk`, `args` is the complete story and whatever `file=` it names
  is used directly — and mutated by boots.

## SSH defaults

`with.ssh.port` is the **host-assigned port** — the target connects to
`127.0.0.1:port`. What port sshd listens on inside the guest is not part of
the surface: the guest side of the forwarding lives where the port forward
is defined, in `args` (`hostfwd=tcp::2222-:22`), authored like any other
QEMU argument.

Every `with.ssh` key falls back, independently, through two layers — the
workflow's globals, then the built-in default:

| ssh key        | global variable         | built-in default |
|----------------|-------------------------|------------------|
| `port`         | `VM_SSH_PORT`           | none (required)  |
| `user`         | `VM_SSH_USER`           | `"root"`          |
| `identity_file`| `VM_SSH_IDENTITY_FILE`  | none             |

The globals are assigned as ordinary Lua globals in the workflow, before
the step:

```lua
VM_SSH_USER          = "admin"
VM_SSH_PORT          = 2222
VM_SSH_IDENTITY_FILE = os.getenv("HOME") .. "/.ssh/id_ed25519"
```

They are read at step-evaluation time, not at workflow load, and each falls
back independently (a step may set `port` while taking the global user and
identity file). `port` and `identity_file` have no built-in default: a
`with.ssh` without any port source is a spec error; without an identity
file, ssh uses the agent/default keys, per the ssh client's own rules.

Note the forwarding must agree between `args` and `ssh.port` — the package
does not parse `hostfwd=` to cross-check it. Convention: bind both to one
Lua value.

```lua
local ssh_port = 2222
-- args = { ..., "-netdev", { user = true, id = "net0",
--          hostfwd = "tcp::" .. ssh_port .. "-:22" }, ... }
-- ssh  = { port = ssh_port }
```

## The serial console

`-serial file:<run_dir>/serial` captures the guest console to a file for the
VM's lifetime. Workflows consume it through `require("pkgs:qemu/serial")`:

* `serial.wait_for(handle_or_name, pattern, timeout_s)` — poll the log until
  the Lua pattern matches; on timeout, fail quoting the log's tail. Used for
  "wait for login prompt", "wait for cloud-init done", device-appearance
  loops, ...
* `serial.tail(handle_or_name, n)` — the last n lines.

## The ssh target

When `with.ssh` is given, `out.target` is a makac remote target named after
the VM. It is an ordinary target as far as the rest of makac is concerned:
later steps take it as `target`, the runner closes it at workflow end, and
`state = "stopped"` closes it as part of its teardown.

The target's connection parameters are `127.0.0.1`, `ssh.port`, and the
configured user/identity/options; connection reuse is the ssh transport's
concern.
