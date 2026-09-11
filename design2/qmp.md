# QMP: `qemu:qmp/send`, `poll`, `consume`, and `pkgs:qemu/qmp`

QMP is QEMU's control protocol: JSON over a unix socket — the one every
`qemu:vm` VM opens at `<run_dir>/qmp.socket`. The package surfaces it as
three actions and a library:

* `qemu:qmp/send` — send commands to a VM, as a step;
* `qemu:qmp/poll` — drain pending events from a VM's event stream;
* `qemu:qmp/consume` — discard events a workflow has finished treating;
* `require("pkgs:qemu/qmp")` — construct command tables, read replies.

A workflow writes and reads Lua tables throughout; the JSON wire format is
not part of its surface.

## The connection model

A started VM has exactly one QMP connection, opened by `qemu:vm` as part of
starting it and held by its handle until the handle is closed — `state =
"stopped"` succeeding, or the workflow run ending. All qmp actions against
the VM share it. Per VM and per run there is exactly one handle, and with
it one connection (handle.md, "One handle per VM per run").

Consequences:

* Commands and polls against one VM serialize on this connection — order is
  the order of steps.
* A run that attaches to an already-running VM by name opens a connection
  at attach time; that connection is the VM's for the rest of the run.
* Events emitted while no connection existed (between runs, or before the
  run attached) are never received; QMP delivers events only to connections
  that exist when they fire. To observe an event, arrange to poll after the
  step that raises it.

## `qemu:qmp/send`

```lua
local res = step {
  name = "attach 4k test namespace",
  uses = "qemu:qmp/send",
  with = {
    vm = vm.out.handle,       -- a handle, or a plain VM name ("testvm")
    commands = {
      { execute = "device_add",   arguments = { driver = "nvme-subsys", id = "subsys.test" } },
      { execute = "device_add",   arguments = { driver = "nvme", id = "nvme-ctrl.2",
                                                 serial = "test", bus = "pcie-root-port.2",
                                                 subsys = "subsys.test" } },
      { execute = "blockdev-add", arguments = { ["node-name"] = "bdev.test", driver = "raw", ... } },
      { execute = "device_add",   arguments = { driver = "nvme-ns", id = "ns.test",
                                                drive = "bdev.test", nsid = 1, ... } },
    },
    -- optional:
    on_error = "fail",        -- "fail" (default): first failed command = step failure
                              -- "collect": run them all, report failures in out
  },
}
```

Semantics:

* Commands are sent **in array order** on the VM's connection — hotplug
  sequences like the above depend on this.
* Each command is `{ execute = "<qmp command>", arguments = {...}? }`.
  `arguments` nests freely (blockdev's `file = { driver = "file", ... }`);
  key names pass verbatim — QMP keys like `node-name`/`if` need bracket
  syntax but otherwise just work.
* A QMP error reply on a command yields `error = { class =, desc = }`.
  `on_error = "fail"`: the step fails, message naming the command and desc.
  `"collect"`: execution continues, `out.results[i].error` carries it.
* A VM whose QMP socket doesn't connect (down/unresponsive) is a step
  failure naming the handle.
* `qemu:qmp/send` never *returns* events. It does, however, discard the
  event buffer when it issues a command: sending declares "a new
  transaction begins — events before it were not asked about". Events
  arriving while the command is in flight are buffered and observed with
  `poll` (below). See "Events" for the full discipline.

Return:

```lua
{
  changed = true,
  out = {
    results = {   -- one per command, in order
      { ["return"] = {...} or nil,    -- the command's "return" payload
        error   = {class=, desc=} or nil },
      ...
    },
  },
}
```

## The library

The library constructs command tables. **It performs no I/O — there is no
socket, no target VM, no sending of anything.** A constructor maps arguments
to a `{ execute = ..., arguments = ... }` table, which a workflow then passes
to `qemu:qmp/send`, the only place commands are sent — and the only place a
VM is named:

```lua
local qmp = require("pkgs:qemu/qmp")

step {
  uses = "qemu:qmp/send",
  with = {
    vm = vm.out.handle,          -- the VM is chosen here, at send time
    commands = {
      qmp.dev_add("nvme", { id = "nvme-ctrl.2", serial = "test", ... }),
      qmp.bdev_add("bdev.test", "raw", { ... }),
    },
  },
}
```

Constructors:

```lua
qmp.dev_add(driver, args)      -- -> { execute = "device_add",
                               --      arguments = merge(args, { driver = driver }) }
qmp.bdev_add(node, driver, args)  -- blockdev-add with node-name/driver injected
qmp.hmp("savevm mysnapshot")   -- -> human-monitor-command table
qmp.query_status()             -- -> { execute = "query-status" }
```

Because they are pure table-builders they compose with ordinary Lua
(merging, loops, conditionals), and the same command table can be sent to
any number of VMs by any number of `qemu:qmp/send` steps.

Reply helpers (also pure) read what a step returns:

```lua
qmp.ok(result)          -- result.error == nil
qmp.err_desc(result)
```

## Hotplug notes

The standard hotplug workflow (see `example_nvme_test.md`) leans on two
QEMU facts that are worth stating here:

* **`addr` is a string.** To assign a device a deterministic PCI BDF, pass
  `addr` explicitly — and as a string (`addr = "0.0"`), never a number. The
  guest then finds the device at a known address, pollable over ssh
  (`lspci -nn`).
* **Q35 cannot hotplug PCIe root ports.** The buses devices attach to must
  exist from boot: pre-create them in the VM's `args` (`pcie-root-port`
  devices with ids) and hotplug `nvme` &c. onto those buses with
  `qemu:qmp/send`. Snapshotting after boot (snapshots.md) freezes this
  topology into base state, so every resumed VM has the ports ready.

## `qemu:qmp/poll` and `qemu:qmp/consume`

Alongside command replies the connection receives asynchronous events
(`DEVICE_DELETED`, `RESET`, ...). Events accumulate in a per-VM buffer, and
two actions manage them:

```lua
local p = step {
  uses = "qemu:qmp/poll",
  with = {
    vm = vm.out.handle,
    timeout_s = 5,     -- optional; how long to listen for events. default 0
  },
}
-- p.out.events == { { name = "DEVICE_DELETED", data = {...} }, ... }
--                 the events drained during this poll
```

```lua
step {
  uses = "qemu:qmp/consume",
  with = {
    vm = vm.out.handle,
    n = #p.out.events,   -- discard the n oldest buffered events
  },
}
```

The model:

* Events accumulate in the buffer until discarded.
* **`qemu:qmp/poll`** drains the socket on the VM's connection (bounded by
  `timeout_s`; a timeout is not an error, it returns with what arrived).
  The events drained during the poll are returned in `out.events` **and
  remain in the buffer**.
* **`qemu:qmp/consume`** discards the `n` oldest buffered events — the ones
  the workflow has finished treating. It knows their count, having received
  them from poll.
* **`qemu:qmp/send` discards the buffer** at the moment it issues its
  commands: a new command is the declaration that events predating it are
  not of interest. To treat events before continuing, poll — and, if they
  should not linger for the next command's lifetime, consume — before
  sending.

The typical pattern — raise a condition, then witness it:

```lua
step {
  uses = "qemu:qmp/send",
  with = { vm = vm.out.handle,
           commands = { { execute = "device_del", arguments = { id = "ns.test" } } } },
}
local p = step { uses = "qemu:qmp/poll",
                 with = { vm = vm.out.handle, timeout_s = 10 } }
assert(p.out.events[1].name == "DEVICE_DELETED")
step { uses = "qemu:qmp/consume",
       with = { vm = vm.out.handle, n = #p.out.events } }
```

(Here the next `send` would have cleared the buffer anyway; `consume` is how
a workflow discards treated events when it does not intend to send next.)

Waiting for a guest-side condition is expressed with polls from steps:
`poll`/`consume` when there's a QMP event; a ssh shell loop or
`serial.wait_for` (vm.md) when the evidence is inside the guest.
