
Tool name: `makac`

`makac init <path>` - initialize a new data-directory at `<path>`. Note that finding the data directory still proceeds according to the algorithm in design/data_directory.md
  - if `<path>` ends with `.makac` - initialize exactly at `<path>`
  - otherwise, add `/.makac` to `<path>`

`makac run <workflow>` - run a workflow file, for example, `makac run my_workflow.lua`. A workflow file can use anything in the Lua 5.4.2 standard library or any of the additional functionality provided to the VM by makac itself.

`makac fetch`
  - download packages described by `.makac/packages.lua`
  - `makac` will NOT automatically fetch dependencies at each run. You must call `makac fetch` when updating/changing dependencies.
