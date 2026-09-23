# Doctor (`makac doctor`)

*Status: done.*

`makac doctor` reports the health of makac itself and of every package the
project lists: required programs present, the data directory writable,
package-specific prerequisites. It is modelled on Neovim's `:checkhealth` —
checks are plain functions that *report*; the runner discovers them, runs
them, and groups the output — except that makac already knows its packages, so
discovery is a lookup rather than a runtime-path scan.

## The report object

Checks never print. They are handed a `health` object and call it:

```lua
health.start(name)            -- a sub-header inside the current group
health.ok(msg)                -- a passing check
health.info(msg)              -- neutral information
health.warn(msg, advice?)     -- a non-fatal problem; bumps the warning count
health.error(msg, advice?)    -- a failure; bumps the error count
health.executable(bin)        -- helper: ok when `bin` is on $PATH, else error
```

`advice` is an optional string or array of strings, printed as advice lines
under the finding. `health.executable` returns a boolean, so a check can
branch on it.

Within a group, `health.start(name)` opens a **sub-section**: a blank line
(unless it opens the group) followed by `  ~ name ~`. Groups head with
`== name ==`, with `N error(s)` / `N warning(s)` appended when nonzero, so the
two levels read differently.

## The check

A check is a function:

```lua
-- <pkg-root>/health.lua
return function(health, pkg_name)
  health.ok("...")
end
```

`pkg_name` is the group's name: `"makac"` for the base group, `"pkgs/<id>"`
for a package. A package uses it to reach its own code — the file lives at the
package root, *outside* `lib/`, so it is not part of the package's require
surface:

```lua
return function(health, pkg_name)
  local ok, util = pcall(require, pkg_name .. "/util")
  if not ok then
    health.error("cannot load " .. pkg_name .. "/util", "the package may not be fetched")
    return
  end
  ...
end
```

The check is the file's return value, not a `{ check = fn }` module: doctor
loads the file itself, so there is no module name and no `require("...")` of
it.

## Discovery and running

`makac doctor [name...]`:

1. the **base group** `makac` first — checks built into the prelude;
2. then each package from `packages.lua`, in file order, under its id.

For each package, `makac.resolve_pkg_dir(def)` gives its root and
`makac.pkg_dirs[id]` is set, so `require(pkg_name .. "/...")` resolves; then
`<pkg-root>/health.lua` is `loadfile`d and its returned function is called with
`(health, pkg_name)`. The package's `makac.lua` is **not** run — checks must be
self-contained.

A package with no `health.lua` reports one line:

```
  no health checks implemented for this package.
```

Every check runs under `pcall`; a raised error is reported as an error line in
its group (naming the package), never a crash.

With no arguments, every group runs; with arguments, only the named ones
(`makac`, or one or more package ids).

## Output

Grouped, base first, to stdout:

```
== makac ==
  - OK    ssh found at /usr/bin/ssh
  - OK    scp found at /usr/bin/scp
  - WARN  curl not found
    - ADVICE: install curl, or use a package that needs no download

== qemu ==  1 error
  - OK    qemu-system-x86_64 found
  - ERROR qemu-img not found
    - ADVICE: install qemu
```

The exit status is `0` unless a check reported an `error` (warnings do not
fail). No emoji (unlike `:checkhealth`); the labels are `OK` / `INFO` / `WARN`
/ `ERROR`.

## Base checks

makac's own group covers what its built-ins shell out to, plus its own state:

* programs on `$PATH`: `sh`, `ssh`, `scp`, `tar`, `git`, `curl`
  (`health.executable`);
* the data directory exists and is writable;
* the makac version (informational).

## Non-goals

* no `--json` yet;
* no auto-fix or install; checks are read-only and best-effort;
* package checks are opt-in (a missing `health.lua` is a note, not a failure).
