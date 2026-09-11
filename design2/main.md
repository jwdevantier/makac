# The QEMU package (design2)

This directory describes the design of the `qemu` package for makac: a
package providing the steps with which to create disk images and manage QEMU
virtual machines.

Every capability is a makac *action* invoked as a *step* within a workflow,
or a *library module* in the package's `lib/` directory. The docs describe
things from the point of view of the workflow author — what the Lua surface
looks like and what it does. `qqmgr_inspiration.md` summarizes the qqmgr
feature set this package is based on; `feasibility.md` lists, separately,
what the design needs from makac itself, `stdlib.md` specifies the extended
stdlib (`makac.*` primitives) those needs resolve to, and `launch.md` pins
down the annotated pseudo-Lua shape of the VM start/stop choreography.

## The nouns

* **VM handle** — the identity of a QEMU process and its runtime files: a
  name plus a runtime directory. Actions that operate on a VM accept a handle
  or just a name. Handles re-derive across separate `makac run` invocations,
  so a VM started by one run can be operated on by another. See `handle.md`.
* **target** — a VM configured for ssh is returned as a makac remote target
  (`out.target`), usable by later steps (`uses = "shell"`, `target = ...`).
* **image** — a disk-image artifact built from a spec and cached by hashes
  of its inputs. See `images.md`.
* **snapshot** — a full VM state (RAM + devices) baked into a VM's disk
  image under a tag by QMP `snapshot-save`, resumable later. See
  `snapshots.md`.

## The verbs (actions)

The package ships with id `qemu`; action references take the form
`qemu:<action>`. (During development it is loaded in place with the
`filesystem` fetcher.)

| action            | purpose                                             | doc            |
|-------------------|-----------------------------------------------------|----------------|
| `qemu:vm`         | set a VM's state: started / stopped / restarted     | `vm.md`, `launch.md` |
| `qemu:qmp/send`   | send QMP commands to a VM                           | `qmp.md`       |
| `qemu:qmp/poll`   | drain pending events from a VM's event stream       | `qmp.md`       |
| `qemu:qmp/consume`| discard events the workflow has finished treating   | `qmp.md`       |
| `qemu:savevm`     | capture a running VM's state to a snapshot file     | `snapshots.md` |
| `qemu:loadvm`     | boot a VM resuming from a snapshot                  | `snapshots.md` |
| `qemu:img`        | ensure an image is built (raw, cloud-init, custom)  | `images.md`    |

## Library modules

* `require("pkgs:qemu/qmp")` — QMP command constructors and reply helpers.
  See `qmp.md`.
* `require("pkgs:qemu/img")` — custom image-builder registration. See
  `images.md`.
* `require("pkgs:qemu/serial")` — waiting for patterns in a VM's serial log.
  See `vm.md`.

## Worked examples

* `images.md` — "Worked example: a cloud-init boot base" (the `bootbase`
  image from qqmgr's `base.toml`).
* `example_nvme_test.md` — the full snapshot + hotplug + vfio test loop
  that motivated the package (image build → boot-once → `savevm` → per-test
  `loadvm` → QMP hotplug → guest-side bind/run → teardown).

## Where state lives

Runtime state is rooted in the project data directory (`makac.data_dir`,
i.e. `.makac/`), and comes in two kinds:

**Shared state** — artifacts keyed and invalidated by *content*, safe for
any number of workflows to use and reuse:

```
.makac/cache/                 download cache (sha256-addressed)
.makac/qemu/img/<name>/       per-image build state (stages, manifests, image)
```

An image named by two workflows is the same image as long as its inputs
hash the same; when they don't, the affected stages rebuild (images.md).
Sharing is the design.

**Named state** — live things keyed by an *author-chosen name*:

```
.makac/qemu/<vm name>/        per-VM runtime files (pid, qmp socket, logs,
                              invocation, overlay disk)
```

All workflows sharing the data directory share VM names. Naming a VM in a
workflow asserts "my VM": if a VM of that name is already running with a
different invocation, `qemu:vm` fails rather than reusing or replacing it
(vm.md, "Invocation identity"). Agreement between workflows is therefore
enforced loudly at `qemu:vm` boundaries; workflows that want isolation pick
different names (or `run_dir` overrides). Runtime state the name does not
cover — disks, hotplugged devices, guest contents — is kept out of the
sharing question by booting onto per-start overlay disks (vm.md, "Overlay
boot disks") and by snapshot-based reuse (snapshots.md).

Defaults everywhere; individual actions accept overrides. State on disk
survives `makac run` exiting: a later run (re-)attaches to a VM by name.

## Non-goals

* Interactivity — no console terminal, no gdb attachment.
* Anything but QEMU/QMP.
