<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Introduction

makac (Czech for "hard worker" or "grinder") is an **orchestrator / runner** written in
[Odin](https://odin-lang.org/). It sits somewhere between a CI system and a test-runner:
you describe *what should happen* — run commands, transfer files, boot machines, gather
facts — and makac carries it out, against your own machine or against remote hosts, in the
order you specify.

Stylistically, makac is a cross between a GitHub Actions-style CI runner and
Ansible-esque *declarative* actions. The difference is the foundation: instead of YAML,
workflows are written in **plain Lua**. A workflow is a Lua program that calls a small
DSL — most importantly `step { ... }` — and because it is ordinary Lua, everything the
language offers (functions, modules, loops, conditionals) is available to structure and
reuse your workflows.

```lua
step {
    name = "say hello",
    uses = "shell",
    with = {
        cmd = { "echo", "hello from makac" },
    },
}
```

## Why makac exists

makac grew out of a specific need: run tests **inside a QEMU VM** to exercise QEMU's NVMe
device code — build the test artifacts, transfer files and assets into the VM, then
execute. None of the existing options fit well:

- **Pure in-language test frameworks** are too narrow. They cannot spawn a VM, transfer
  files and assets into it, and then run tests inside it.
- **Ansible** could do the job, but only with several custom modules anyway — and it stays
  clunky, because Jinja2 + YAML is a poor medium for the kind of reuse a real test suite
  needs (for example importing sub-playbooks).
- **GitHub Actions** is woefully inadequate here: you would be forced to submit changes to
  it for every run, and some code simply cannot be shared with the runner at all during
  development.

The result is a tool that keeps what makes Ansible and GitHub Actions pleasant —
declarative, reusable steps and pluggable actions — while replacing the YAML with a real
programming language:

- **Flexible and compact.** Lua is far denser than YAML, and functions, modules and loops
  make it easy to factor out repeated work.
- **Declarative where it counts.** Workflows stay structured as a sequence of steps, like
  an Ansible playbook, rather than turning into imperative scripts.
- **Pluggable.** Like GitHub Actions, external actions can be pulled in through makac's
  package system (see [Packages & the data directory](concepts/packages.md)).

## Dependencies

makac is deliberately light on dependencies: building it needs only the Odin compiler.
See [Getting Started](getting-started.md) for build instructions.

## The QEMU package

The QEMU integration that started it all — booting VMs, snapshots, live device hotplug via
QMP, and the NVMe test loop — is being developed as a **separate package**, not part of
makac core. It is documented on its own page: [The makac QEMU package](qemu-package.md).

## About this book

- [Getting Started](getting-started.md) — build makac and run your first workflow.
- [Concepts](concepts/index.md) — workflows, steps, actions, targets, facts, and packages.
- [Reference](reference/index.md) — the CLI, the step specification, built-in actions and
  the Lua standard library.
- [Examples](examples/index.md) — complete, runnable workflows.
