<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# The makac QEMU package

The QEMU package is the plugin that turns makac into a VM orchestrator: it adds
steps to build disk images, manage QEMU virtual machines, take and resume
snapshots, and talk to a running VM over QMP.

It is **a separate project** with its own repository, documentation site, and
release lifecycle:

- Repository: **<https://github.com/jwdevantier/makac.qemu>**
- Documentation: **<https://jwdevantier.github.io/makac.qemu/>** — the full
  user manual: concepts, per-action reference, and the NVMe snapshot + hotplug
  example loop

## What it does (in one breath)

The package ships under the id `qemu`, so its actions are referenced as
`qemu:<action>` in workflows:

- `qemu:img` — ensure a disk image is built: a raw blank, a
  cloud-init-customized OS image, or a fully custom builder;
- `qemu:vm` — set a VM's state: started / stopped / restarted (a started VM is
  returned as an ssh target for `shell` steps);
- `qemu:savevm` / `qemu:loadvm` — capture a running VM's state (RAM + devices)
  into its image under a tag, and boot a VM resuming from such a snapshot —
  the "boot once, test many times" trick;
- `qemu:qmp/send` / `qemu:qmp/poll` / `qemu:qmp/consume` — send QMP commands to
  a VM (e.g. hotplug a device) and handle its event stream;
- plus library modules such as `require("pkgs:qemu/qmp")` (QMP command
  constructors) and `require("pkgs:qemu/img")` (custom image builders).

The [QEMU + NVMe example](examples/qemu-nvme.md) shows the whole loop these
actions enable: build an image, boot once, snapshot, resume in seconds, hotplug
an NVMe controller while the guest runs, assert its shape, and tear down.

## Where the code lives

The package is developed in its own repository (`makac.qemu`; it lived in
`./extras/makac-qemu/` here before the move). Its detailed design notes
live in `design/` in the package repository — those are implementer notes;
the user-facing documentation ships in the makac.qemu repository itself.
