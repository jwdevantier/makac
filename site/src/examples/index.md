<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Examples

This chapter shows makac in action. The examples are written to be readable —
and, where noted, runnable — with a real installation:

| Example | Shows |
| --- | --- |
| [A simple workflow](simple.md) | A minimal runnable workflow: project init, shell steps, facts, and result handling. No packages required. |
| [QEMU + NVMe: boot, snapshot, hotplug, test](qemu-nvme.md) | The headline demo: build an image, boot a VM, snapshot it, resume from the snapshot in seconds, hotplug an NVMe controller via QMP while the guest runs, and assert its shape. |

The QEMU example uses the [makac QEMU package](../qemu-package.md), a separate
project that is linked from this book but documented on its own.

All snippets follow the conventions from the [Reference](../reference/index.md)
chapter. Remember that a workflow is plain Lua: the `step {}` calls below could
be wrapped in loops, conditionals, or functions of your own — the examples keep
it linear for clarity.
