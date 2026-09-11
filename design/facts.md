# Facts

- facts are collected by the built-in `facts` action — an action like any other
  (e.g. `shell`)
- unlike Ansible, collecting facts is not an obligatory phase:
  - you choose *when* to collect facts
  - you choose *which* and *how many* fact finders to run in one go
- a *fact finder* is a small Lua function that:
  - takes a target
  - runs commands on that target to determine some information
  - returns an associative table of whatever it wants to expose
  - signature `function (target) return {...} end`
- the `facts` action is given an associative table `namespace -> finder`:
  - each key becomes a namespace under `res.out.facts.<key>`
  - each value is a finder — a built-in referred to by name, or a
    custom/imported one (e.g. from a package's `lib/`)

## Built-in finders

* `os` — operating system and architecture of the target, from `uname -s` and
  `uname -m`: `{ os = "linux", arch = "x86_64" }`
* `env` — the target's environment variables, as a `NAME -> value` table
  (from `env`)

```lua
facts = step {
  name = "Gather system facts",
  uses = "facts",
  with = {
    -- plug in the fact finders you want to run
    finders = {
      os = "os" -- simple, builtin,
      env = "env"
    },
    -- optional: if omitted, run directly on runner
    -- target = vm1,
  }
}
```
