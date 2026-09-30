
Tool name: `makac`

`makac init <path>` - initialize a new data-directory at `<path>`. Note that finding the data directory still proceeds according to the algorithm in design/data_directory.md
  - if `<path>` ends with `.makac` - initialize exactly at `<path>`
  - otherwise, add `/.makac` to `<path>`

In both cases, an empty `makac_project.lua` is created next to the data directory (if absent),
so the project is immediately ready to declare packages (see design/packages.md).

`makac run <workflow> [args...]` - run a workflow file, for example, `makac run my_workflow.lua`. A workflow file can use anything in the Lua 5.4.2 standard library or any of the additional functionality provided to the VM by makac itself.

`makac <workflow> [args...]` - implicit form of `run`: if the first argument is not a recognized subcommand (`init`, `run`, `fetch`, `doctor`), it is treated as a workflow file to run. (This means a workflow named exactly like a subcommand cannot be invoked this way — accepted ambiguity.)

Either way the workflow runs with these globals set:

  - `arg` — array-like table of the command-line arguments after the workflow, passed through verbatim: `arg[0]` is the workflow path as given, `arg[1]`, `arg[2]`, ... are the arguments after it (dashes intact, e.g. `--flag` stays `--flag`)
  - `SCRIPT_DIR` — absolute path of the directory the workflow resides in
  - `PROJECT_DIR` — the project root, i.e. the directory holding the `.makac` data directory and `makac_project.lua` (same value as `makac.project_root()`); defined in every VM that has a data directory, not only when running a workflow

A workflow file may also be executable directly, via a shebang line:

```lua
#!/usr/bin/env makac
print("hello, world")
```

The interpreter skips the shebang line (without shifting error line
numbers, matching stock Lua's `luaL_loadfilex`). If the script is not
inside a project — no `.makac` or `.git` in any ancestor directory — it
runs WITHOUT a data directory: packages are not loaded, `PROJECT_DIR` is
nil, and data-dir-dependent functionality (`makac.download`,
`makac.fetch_all`, ...) raises an error when used.

`makac fetch`
  - download packages described by `makac_project.lua` (its `inputs` table)
  - `makac` will NOT automatically fetch dependencies at each run. You must call `makac fetch` when updating/changing dependencies.
