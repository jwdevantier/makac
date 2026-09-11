# Actions
Actions are inspired by Ansible in that they should describe a desired end-state rather than an operation to perform (declarative rather than imperative).

Actions are invoked as a *step*, a action step might look like so:
```lua
local result = step {
  -- optional: action should provide a default name to use
  -- (but it gets easier to follow the output given descriptive names)
  name = "do a thing",

  -- denotes which action is used.
  -- example of an external action defined in the package aliased 'qemu' (see design/packages.md)
  uses = "qemu:vm",

  -- (optional) additional arguments passed to the action, these vary by action
  with = {
    state = "started",
    conf = {}, -- vm conf, imagine
  }
}
```

## Action return value
Actions return a result table; makac normalizes it (`makac.normalize_result`),
filling in defaults, so callers can always rely on this shape:
```lua
{
  -- string: set IF AND ONLY IF the action failed; describes what went wrong
  -- (absent otherwise — failure is never reported via the other keys)
  err = nil,
  -- bool: true if action changed system state (defaults to false)
  changed = false,
  -- bool: true iff action was skipped (defaults to false)
  skipped = false,
  -- table: holds any values the action itself wants to return, varies by
  -- action (defaults to an empty table)
  out = {}
}
```

A step whose action raises, or whose result sets `err`, aborts the workflow
(see design/steps.md).

## How actions are implemented
Actions should be implemented in Lua, the program may gather information and cause state change on the target machine (see design/target.md) by executing shell commands, with the lua code driving decision-making.

## Built-in actions
A small subset of actions are built-in, these are identified by not containing any ':' characters.
See design/packages.md for details, but essentially, a project may depend on external packages.

## Remote actions
Remote actions are fetched from elsewhere, see design/packages.md for details, but it involves declaring a list of packages to fetch - and how to fetch from them.

Every package is given a unique name which is used later when identifying an action to take. References to external actions will take the form of `<package id>:<action name>`, where the part before the `:` is the package id and the part after is the action name. A package id can therefore not itself contain a `:` — a reference without one denotes a built-in action.

