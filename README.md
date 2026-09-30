# makac

**makac** (Czech *Makáč* — a hard worker) is an orchestrator/runner, written in
[Odin](https://odin-lang.org/). Think GitHub Actions meets Ansible — but with
workflows written in **plain Lua** instead of YAML. Describe what should happen
— run commands, transfer files, boot VMs, gather facts — and makac executes it
on your machine or on remote hosts over SSH, in the order you specify.

```lua
step {
    name = "say hello",
    uses = "shell",
    with = { cmd = { "echo", "hello from makac" } },
}
```

Because a workflow is ordinary Lua, functions, loops and modules are all
available to structure and reuse your steps; external actions are pulled in
through a package system.

## Quick start

```bash
odin build . -out:makac   # or: nix develop, then the same
./makac init .            # initialize a .makac data directory
./makac example.lua       # run a workflow
```

## Documentation

Full documentation: **<https://jwdevantier.github.io/makac/>**

## License

Code is [BSD-2-Clause](LICENSES/BSD-2-Clause.txt); documentation is
[CC0-1.0](LICENSES/CC0-1.0.txt). This project is
[REUSE](https://reuse.software/) compliant.
