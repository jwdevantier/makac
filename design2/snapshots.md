# Snapshots: `qemu:savevm` and `qemu:loadvm`

A *snapshot* is a VM's full live state — RAM and device state — *baked into
its disk image* under a tag, captured from a running VM and resumable later.
This is QEMU's internal-snapshot mechanism: QMP `snapshot-save` /
`snapshot-load` (HMP's `savevm`/`loadvm`), and `-loadvm <tag>` on the QEMU
command line.

The shape this gives workflows: bring a VM to a known state, snapshot it,
then boot VMs resuming *from the snapshot in the image* — skipping boot —
use them, throw them away.

**Requirements.** All writable block devices of the VM must support internal
snapshots — in practice: qcow2, including the overlay disks `qemu:vm`
creates (vm.md). A VM with a raw or otherwise snapshot-uncapable writable
device gets a step failure quoting QMP's error and naming the device.

## `qemu:savevm`

```lua
local snap = step {
  name = "snapshot the VM",
  uses = "qemu:savevm",
  with = {
    vm   = vm.out.handle,   -- handle or name; must be running
    tag  = "ready-state",   -- optional; default: timestamped tag
  },
}
-- snap.out.snapshot == "ready-state"   (the tag)
```

Semantics:

* The VM must be running; anything else is a step failure quoting the probe
  (handle.md).
* Capture: QMP `snapshot-save` with the tag over the VM's writable devices.
  The guest is quiesced for the capture (the mechanism's own freeze) and
  keeps running after.
* A QMP error (uncapable device, duplicate tag, ...) is a step failure
  naming the command and the QMP error description.
* `out.snapshot` is the tag. The snapshot lives *in the image file* —
  it survives the VM dying and `makac` exiting, and travels with the image
  (copy the image, the snapshot comes along).

## `qemu:loadvm`

```lua
local vm2 = step {
  name = "resume vm",
  uses = "qemu:loadvm",
  with = {
    name     = "testvm-resumed",
    qemu_bin = vm_qemu_bin,
    args     = saved_args,       -- the VM's args (see below)
    snapshot = snap.out.snapshot,   -- required: the tag
    state    = "started",        -- "started" (default) | "restarted"
    ssh      = {...},            -- optional, as in qemu:vm
  },
}
```

`qemu:loadvm` is `qemu:vm` with one additional input: `snapshot` makes the
launch append `-loadvm <tag>`, so the guest resumes where it was captured
rather than booting.

Rules:

* `state = "started"` on a running VM is idempotent as with `qemu:vm`. The
  canonical invocation (vm.md, "Invocation identity") includes the snapshot
  tag, so "same VM, new tag" is a different invocation and must be spelled
  `state = "restarted"`.
* The caller supplies `args`. Resuming requires the machine configuration
  the snapshot was taken with; the image records state, not configuration.
  *Control interfaces are exempt*: pidfile, QMP/HMP sockets and the serial
  log are per-run infrastructure (vm.md, "Auto-injected runtime arguments")
  and may differ freely between the save-side and load-side launches.
* The image holding the tag must be the one the VM's disks resolve to: for
  an overlay-booted VM the snapshot lives in `<run_dir>/disk.qcow2` of the
  VM it was saved from — resume on that same run dir (the same VM name).
  `qemu:loadvm` accordingly *keeps* the existing overlay rather than
  recreating it (vm.md, "Overlay boot disks").
* A tag not present in the image fails at launch: QEMU exits, and the step
  failure quotes the qemu-stderr log per `qemu:vm`'s launch rules.

## Housekeeping

QMP also has `snapshot-delete` (HMP `delvm`). No dedicated action for v1:
deleting is `qemu:qmp/send` with
`{ execute = "snapshot-delete", arguments = { job-id = ..., name = tag, devices = {...} } }`
through the existing surface.
