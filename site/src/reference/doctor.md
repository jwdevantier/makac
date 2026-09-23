<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Doctor

`makac doctor` reports the health of makac itself and of every package the
project lists: required programs, whether the data directory is usable, and
whatever each package needs checked. It is the first place to look when a
workflow fails with a missing command or prerequisite.

## Running it

```bash
makac doctor              # every group
makac doctor qemu          # only the qemu package's group
makac doctor makac qemu    # the base group and the qemu group
```

Group names are `makac` (makac's own checks) and the package ids from
`.makac/packages.lua`.

## Output

Groups are printed base-first. Each heads with `== name ==` — with
`N error(s)` / `N warning(s)` appended when nonzero — then one line per
finding:

```text
== makac ==
  - OK    sh found at /usr/bin/sh
  - OK    ssh found at /usr/bin/ssh
  - INFO  makac 0.3

== qemu ==  1 error
  ~ programs ~
  - OK    qemu-img found at /usr/bin/qemu-img
  - ERROR genisoimage not found
    - ADVICE: needed only by the cloud-init builder; install cdrkit/genisoimage
```

- `OK` — the check passed.
- `INFO` — neutral information.
- `WARN` — something is wrong but not fatal (it does not fail the command).
- `ERROR` — a real failure.
- an `- ADVICE:` sub-line suggests what to do about a `WARN`/`ERROR`.

`health.start(name)` inside a check opens a sub-section (`~ name ~`).

The exit status is non-zero iff any check reported an `ERROR`; warnings do not
fail. The base group runs with or without a project; package checks need a
resolvable data directory.

## Writing a check

A package adds a check by shipping a `health.lua` at its root — next to, not
inside, its `lib/`:

```lua
-- <pkg-root>/health.lua
return function(health, pkg_name)
  health.start("programs")

  health.executable("mytool")     -- OK when on $PATH, else ERROR + advice

  health.info("checked " .. pkg_name)
  health.error("something is missing", { "install it", "or configure it" })
end
```

The file must return a function; doctor calls it with two arguments:

- **`health`** — the report object:
  - `health.start(name)` — open a sub-section;
  - `health.ok(msg)` / `health.info(msg)` — a pass / neutral line;
  - `health.warn(msg, advice?)` / `health.error(msg, advice?)` — a warning /
    failure; `advice` is a string or an array of strings;
  - `health.executable(bin)` — `OK` when `bin` is on `$PATH`, else `ERROR`
    (and returns a boolean).
- **`pkg_name`** — the group's name: `"makac"` for the base group, `"pkgs/<id>"`
  for a package. Use it to reach the package's own code:

  ```lua
  local util = require(pkg_name .. "/util")   -- <pkg-root>/lib/util.lua
  ```

The check file itself is loaded by doctor (via `loadfile`), not `require`d, and
the package's `makac.lua` is **not** run — a check must be self-contained.
Doctor runs every check under `pcall`: a check that raises is reported as an
error line, never a crash. A package with no `health.lua` reports a single
`no health checks implemented for this package.` line.

## makac's own checks

The `makac` group verifies the programs the built-ins shell out to — `sh`,
`ssh`, `scp`, `tar`, `git`, `curl` — that the data directory is writable, and
reports the version.
