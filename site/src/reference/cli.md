<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# CLI

`makac` is a single binary with four commands and one flag:

```text
usage: makac [--version] <command> [args]

commands:
  init <path>       initialize a .makac data directory
  run <workflow>    run a workflow file
  fetch             fetch packages listed in .makac/packages.lua
  doctor [name...]  report the health of makac and its packages

flags:
  --version       print version (major.minor) and exit
```

## `makac init <path>`

Initializes a makac data directory (`.makac`) at `<path>`:

- if `<path>` ends with `.makac`, it is used exactly as given;
- otherwise makac creates `<path>/.makac`.

```bash
$ makac init myproject
makac: initialized data directory at myproject
```

Creating an already-existing data directory is not an error. `init` is how you
set up a project when makac cannot find a project root on its own (see
[The data directory](../concepts/packages.md)).

## `makac run <workflow>`

Evaluates a workflow file (any Lua file) top to bottom, in a fresh VM that has
the full Lua 5.4 standard library plus the `makac.*` primitives and DSL (see
[Lua standard library](lua-stdlib.md)):

```bash
makac run my_workflow.lua
```

Before the workflow itself runs, makac loads every package listed in
`.makac/packages.lua` (in file order), merging their actions and fetchers into
the registries under their `<id>:` prefix and making their `lib/` require-able
via `require("pkgs/<id>/...")`. A listed-but-not-fetched package aborts the run
with an error telling you to run `makac fetch` first. No package list means no
packages — silently.

When the workflow finishes — successfully **or** by failing — makac closes every
target the workflow used, then exits.

## `makac fetch`

Fetches every package listed in `.makac/packages.lua` into
`.makac/packages/<id>/`, in file order, using each entry's declared fetcher.
Fetching is **never** automatic: you run `makac fetch` yourself, whenever you
add or change dependencies.

```bash
$ makac fetch
defined packages (#1):
  1. qemu (fetcher: fetchgit)
fetching qemu via fetchgit...
fetched qemu
```

If no `packages.lua` exists yet, `makac fetch` is **not** an error — it prints
where the file lives and an example entry, and exits 0:

```text
makac: no packages.lua found.

The package list for this project lives at:
  /path/to/project/.makac/packages.lua
...
```

Any fetch failure (unknown fetcher, checksum mismatch, network error, bad
`with` arguments) aborts the whole fetch run with a non-zero exit.

## `makac doctor`

Reports the health of makac itself and of every package the project lists:
required programs on `$PATH`, the data directory writable, and each package's
own checks. Output is grouped, base group `makac` first:

```text
== makac ==
  - OK    ssh found at /usr/bin/ssh
  - OK    scp found at /usr/bin/scp
  - WARN  curl not found
    - ADVICE: install curl

== qemu ==  1 error
  - OK    qemu-system-x86_64 found
  - ERROR qemu-img not found
    - ADVICE: install qemu
```

A package's own group is produced by a `<pkg-root>/health.lua` check (the
package author's contract is documented in makac's `design/doctor.md`); a
package without one reports a single "no health checks implemented" line.

`makac doctor [name...]` runs every group, or only the named ones (`makac`, or
package ids). The exit status is non-zero iff any check reported an error —
warnings do not fail. Base checks also run outside a project (package checks
need a resolvable data directory).

## `--version`

Prints the version as `major.minor` and exits:

```bash
$ makac --version
0.3
```

The flag lives on the root command, so `makac --version` works from anywhere —
no data directory is resolved, no VM is created. The same `major.minor` pair is
available to workflows as `makac.env.version()` (see
[Lua standard library](lua-stdlib.md)).

## Exit behavior

| Situation | Exit code |
| --- | --- |
| `makac --version` | 0 |
| `makac fetch` with no `packages.lua` | 0 (informational) |
| Successful `makac run` / `makac fetch` | 0 |
| Unknown command, missing/extra arguments, unparseable flags | 1 (usage printed to stderr) |
| `makac run` workflow failure (a step failed, or the workflow raised) | 1 |
| `makac fetch` failure (bad entry, fetch error) | 1 |
| `makac doctor` with no error findings | 0 |
| `makac doctor` with an error finding, or an unknown group | 1 |
| `makac run` / `makac fetch` with no resolvable data directory | 1 (with advice: `makac init <path>`) |
| `makac init` failure (could not create directory) | 1 |

Error messages go to stderr; informational output from fetch goes to stdout.

## The data directory

`run` and `fetch` locate the data directory from the current working directory
by walking up: the first `.makac` found wins; otherwise the first `.git` found
gets a `.makac` created beside it; if neither exists anywhere up to the
filesystem root, makac errors and suggests `makac init <path>`. See
[Packages & the data directory](../concepts/packages.md) for the full rules.
