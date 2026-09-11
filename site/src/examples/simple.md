<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# A simple workflow

This example is a complete, runnable workflow that needs nothing but makac
itself — no packages. It walks through the shape of a typical run: gather some
facts, do some work with shell steps, and react to the results.

## Setting up a project

makac stores its project state in a data directory (`.makac`). Initialize one
anywhere:

```bash
$ mkdir demo && cd demo
$ makac init .
makac: initialized data directory at demo
```

(You can also just start writing workflows — makac finds the data directory by
walking up from the current directory, creating `.makac` at the first `.git` it
finds. See [Packages & the data directory](../concepts/packages.md).)

## The workflow

Save this as `hello.lua`:

```lua
-- hello.lua — a first makac workflow
--
-- Steps run immediately, in order, from top to bottom. Because this is plain
-- Lua, the whole file is just a program: you can loop, branch, and factor
-- steps into functions.

-- 1. Gather facts about the host makac runs on. We pick exactly the finders
--    we want; nothing is gathered automatically (see the Facts concept page).
local facts = step {
    name = "gather host facts",
    uses = "facts",
    with = {
        finders = {
            os  = "os",   -- built-in: uname -s / uname -m
            env = "env",  -- built-in: the target's environment
        },
    },
}

-- Facts are plain data; branch on them like any Lua table.
local os_name = facts.out.facts.os.os
local arch    = facts.out.facts.os.arch
print(("host: %s/%s"):format(os_name, arch))

-- 2. A shell step. The command is a list of words, executed directly (no
--    shell interpretation on the host); stdout and stderr come back captured.
local whoami = step {
    name = "who are we",
    uses = "shell",
    with = {
        cmd = { "whoami" },
    },
}
print("running as: " .. whoami.out.stdout:gsub("%s+$", ""))

-- 3. A step whose exit code we treat as data. By default a non-zero exit
--    fails the step (and aborts the workflow); `ignore_exit_code = true`
--    hands the decision to us instead.
local exists = step {
    name = "check marker file",
    uses = "shell",
    with = {
        cmd = { "test", "-f", "marker.txt" },
        ignore_exit_code = true,
    },
}

if exists.out.code == 0 then
    print("marker.txt exists")
else
    -- 4. The workflow decides to do something about it: create the file.
    local made = step {
        name = "create marker",
        uses = "shell",
        with = {
            cmd = { "sh", "-c", "echo created by makac > marker.txt" },
        },
    }
    print(("created marker (changed=%s)"):format(tostring(made.changed)))
end

-- 5. Use facts to make a decision about *where* to run something.
if arch == "x86_64" then
    step {
        name = "arch-specific check",
        uses = "shell",
        with = { cmd = { "uname", "-m" } },
    }
end

print("all done")
```

## Running it

```bash
$ makac run hello.lua
run: [host] gather host facts
ok: [host] gather host facts (0.0s)
host: linux/x86_64
run: [host] who are we
changed: [host] who are we (0.0s)
running as: nixos
run: [host] check marker file
ok: [host] check marker file (0.0s)
marker.txt exists
all done
```

The `run:`/`ok:`/`changed:` lines are makac's step progress report, on stderr;
everything else is the workflow's own output on stdout. Note the second run —
with `marker.txt` present, the workflow simply takes the other branch:

```bash
$ makac run hello.lua
run: [host] gather host facts
ok: [host] gather host facts (0.0s)
host: linux/x86_64
run: [host] who are we
ok: [host] who are we (0.0s)
running as: nixos
run: [host] check marker file
ok: [host] check marker file (0.0s)
marker.txt exists
all done
```

A workflow is re-runnable: steps are just Lua, so the same file expresses
"ensure this state" naturally — exactly the Ansible-style *declarative* flavor
makac aims for, without leaving Lua.

## What happened, conceptually

- **Facts** were gathered exactly when we asked, with only the finders we
  listed ([Facts](../concepts/facts.md)).
- **Steps** ran immediately and returned their results; we branched on them
  with plain Lua control flow ([Steps](../concepts/steps.md)).
- **Failure** aborted the workflow: if `test -f marker.txt` had exited non-zero
  *without* `ignore_exit_code`, the run would have stopped with a `failed:`
  line naming the step. There is no continue-on-error field — if you want to
  handle an outcome, keep the step from failing and handle the data
  ([Step specification](../reference/step.md)).
