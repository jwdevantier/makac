<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Workflows

A **workflow** is a Lua file that describes what makac should do. You run it with
`makac run <workflow.lua>`; makac evaluates the file from line 1 onwards, top to
bottom, and every `step { ... }` call executes **immediately**, at the moment it is
evaluated.

## A workflow is just Lua

Because execution is driven by evaluation, a workflow is an ordinary Lua program —
anything in the Lua 5.4 standard library is available, plus the `makac.*`
primitives and DSL functions makac embeds into the VM. There is no separate
"workflow language" to learn beyond the small DSL surface (`step { ... }` and
friends, documented in the [Reference](../reference/index.md) chapter).

This has one important consequence: **steps can sit anywhere in plain Lua control
flow**. The workflow decides which steps run, when, and how often — a step inside a
loop runs once per iteration, a step inside a conditional runs only when the
condition holds, and steps can be produced by functions and reused across many
call sites.

## Control flow, not scheduling

Compare this with a YAML-based runner, where a "workflow" is a data structure
that the runner interprets and schedules. In makac the workflow *is* the program:
there is no interpreter between your Lua and the steps. Want to run the same
sequence of steps for each of several VMs? Write a Lua function that takes a VM
and emits the steps; call it per VM.

```lua
local function check_guest(vm)
    step {
        name = "check guest",
        uses = "shell",
        target = vm,
        with = {
            cmd = { "uname", "-a" },
        },
    }
end

-- run the check on two VMs
check_guest(vm1)
check_guest(vm2)
```

## Workflow files

There is no special file extension or directory convention — a workflow is any
Lua file. A workflow can use `require` and local files, and packages fetched into
the project can be loaded with `require("pkgs/<id>/...")` (see
[Packages & the data directory](packages.md)). Because a workflow is evaluated
once, top to bottom, later steps see the results (and targets) of earlier steps
as plain Lua values — chaining is a natural consequence:

```lua
local boot = step {
    uses = "qemu:vm",          -- from a fetched package (see packages.md)
    with = { state = "started" },
}

step {
    uses = "shell",
    target = boot.out.target,  -- the VM the previous step started
    with = {
        cmd = { "echo", "hello from the VM" },
    },
}
```

## One workflow, one run

A `makac run` invocation evaluates exactly one workflow file. When the evaluation
finishes, makac closes every target the workflow used (see
[Targets](targets.md)) — whether the workflow succeeded or failed — and exits.
For how a single step reports and how failures abort the run, see
[Steps](steps.md).
