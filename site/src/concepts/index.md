<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Concepts

This chapter introduces the ideas that make up a makac workflow. Read it top to
bottom if you are new; each page builds on the ones before it.

## The model in one paragraph

A **workflow** is a Lua file that makac evaluates from top to bottom. As it is
evaluated, the workflow calls `step { ... }` — each call is a **step**: a concrete
instantiation of an **action**, executed the moment it is reached. Actions run on
the host, and reach other machines through the **target** abstraction: a target is
"somewhere I can run commands and read/write files". Targets come in two kinds —
the host itself, and remote hosts reached over SSH — and every target offers the
same three operations: run a command, put files onto it, get files from it.
Host information gathered by the built-in `facts` action (e.g. OS and
architecture) is captured in **facts**, which workflows can use to decide what to
do next. Finally, external actions are brought in as **packages**, declared in
`.makac/packages.lua` and fetched explicitly with `makac fetch`; the package id
becomes the `uses` prefix, e.g. `qemu:vm`.

## The pages

| Page | What it covers |
| --- | --- |
| [Workflows](workflows.md) | What a workflow file is, and how evaluation drives execution. |
| [Steps](steps.md) | The `step { ... }` call: the step spec and its fields, status reporting, and failure handling. |
| [Actions](actions.md) | What an action is, the result shape every action returns, and the built-in actions. |
| [Targets](targets.md) | The host/remote abstraction: `run`, `put`, `get`, naming, and lifecycle. |
| [Facts](facts.md) | Gathering host information with the `facts` action and fact finders. |
| [Packages & the data directory](packages.md) | External actions via `.makac/packages.lua`, fetchers, and how makac locates the data directory. |

## A minimal workflow using most of the model

```lua
-- gather facts about the machine makac runs on
local facts = step {
    uses = "facts",
    with = {
        finders = { os = "os" },
    },
}

-- a step per architecture: run a different command on x86_64
step {
    name = "check architecture",
    uses = "shell",
    with = {
        cmd = facts.out.facts.os.arch == "x86_64"
            and { "echo", "x86_64 host" }
            or  { "echo", "other architecture" },
    },
}
```

Every piece of this — why the steps run in order, what the result tables mean,
where `facts.out` comes from, and how packages extend `uses` — is explained in the
pages that follow. For the full reference, see the [Reference](../reference/index.md)
chapter.
