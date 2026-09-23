The program provides a lua vm with the lua 5.4+ VM plus additional functionality exposed to the VM through functions implemented in Odin.

Also, the program shall provide a small set of built-in actions (see design/action.md).
Because actions are essentially implemented in Lua, it becomes possible to fetch and use externally defined actions. We will call
a bundle of lua code and actions a *package*.

The program shall provide a means of automating the fetching of external packages.
To this end, we create `.makac/packages.lua` (where `.makac` is the data directory, see design/data_directory.md for details on where this directory is located).

## Defining dependencies
`packages.lua` must return a array-like table whose elements must minimally be tables with the `id` and `fetcher` keys set. (To read more about fetchers, see design/fetchers.md)
The `id` key becomes the prefix used in workflows when referring to actions defined by this package.

`.makac/packages.lua` shall define the external packages available in our project.

```lua
-- must return a table of elements
-- elements shall be fetched in the order given
-- this permits earlier packages to provide specialized fetchers for fetching
-- later defined packages
return {
  {
    -- defines the dependency id
    -- to refer to action 'hello' in this dependency we assigned ID 'qemu', write
    -- 'qemu:hello'
    id = "qemu",
    fetcher = "fetchgit",
    with = {
      url = "https://github.com/jwdevantier/qemu.makac",
      rev = "1c194ed",
    }
  }
}
```

## Package layout

A package must have a `makac.lua` file in its root, this is what exports definitions out of the package and into makac proper:

```lua
return {
  fetchers = {
    -- provide a custom fetcher for other dependencies to use
    fetchcvs = function(args, destdir) ... end,
  },
  -- provide one or more new actions
  actions = {
    hello = ...,
    reload = ...,
  },
}
```

If the package contains a `./lib` dir, that directory is added to the package loader under the key `pkgs/<id>` where `id` is the id of the entry in `packages.lua`. To access `./lib/a.lua` if the package had id 'foo', one would then write `require('pkgs/foo/a')`

