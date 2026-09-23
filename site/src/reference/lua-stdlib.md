<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Lua standard library

Workflows are evaluated in a Lua 5.4 VM. Everything in the Lua 5.4 standard
library is available, plus the DSL surface (`step`, package registries) and the
`makac.*` primitives documented here. These primitives are split into two
groups: those baked into the VM (implemented in Odin) and those defined by the
embedded Lua prelude (which build on the Odin ones).

The prelude is evaluated once, before any user-facing Lua, so every workflow
sees everything below. `makac` may already hold Odin-side primitives before the
prelude runs; the prelude only extends it.

## The workflow DSL (prelude-defined)

### `step { ... }`

Instantiates an action and runs it immediately. Full spec in
[Step specification](step.md).

### Targets

| Primitive | Description |
| --- | --- |
| `makac.host` | The host target (machine makac runs on). Always available. |
| `makac.is_target(v)` | Returns true if `v` is a target (table with `kind` `"host"`/`"remote"` and `run`/`put`/`get`/`close` methods). |
| `makac.resolve_target(with)` | Resolves a `with` table to the target it runs against: `with.target` when given, else `makac.host`. |
| `makac.make_target(kind, name, ops)` | Constructs a target from ops functions `{ run(self, argv, opts), put(self, src, dst), get(self, src, dst), close(self) }`, wrapping them with the lifecycle rules (idempotent close, closed-target checks). Kinds are fixed: `"host"`/`"remote"`. |
| `makac.new_target(spec)` | Constructs a target from a plain spec `{ kind, name, run(argv, opts) -> {code, stdout, stderr}, put?, get?, close? }`; missing `put`/`get` raise "not supported". |
| `makac.new_ssh_target(name, spec)` | An SSH-backed remote target: `{ host, user, port?, options? }`. Auth happens once; later ops multiplex. |
| `makac.close_all_targets()` | Closes every live target (reverse order, best-effort). Called by `makac run` after the workflow, even on failure. |

Target operations (`run`/`put`/`get`/`close`) are documented on the
[Targets](target.md) reference page.

### Registries (for package/action authors)

| Primitive | Description |
| --- | --- |
| `makac.define_action(name, fn, opts)` | Registers action `name`; `fn(with)` returns a result table (normalized by `run_action`). `opts.default_name` is used by `step` when a step omits `name`. Redefining an action is an error. |
| `makac.run_action(uses, with)` | Resolves `uses` in the registry, invokes it with `with`, normalizes and returns the result. Unknown actions raise; a raising action is wrapped with an error naming the action. |
| `makac.normalize_result(res)` | Fills in the result defaults: `changed=false`, `skipped=false`, `out={}`. `err` is left as-is (absent unless set). |
| `makac.register_fetcher(name, fn)` | Registers a fetcher for `packages.lua` entries (see [Fetchers](fetchers.md)). |
| `makac.register_fact_finder(name, fn)` | Registers a fact finder for the `facts` action (see [Built-in actions](actions.md)). |

### Package loading (used by the CLI, usable in workflows)

| Primitive | Description |
| --- | --- |
| `makac.data_dir` | The VM's data directory (may be the empty string for a data-dir-less VM). |
| `makac.pkg_dirs` | Maps each loaded package id to its code root on disk. |
| `makac.read_package_defs(data_dir?)` | Reads and validates `<data_dir>/packages.lua`, returning an array of entry tables. |
| `makac.resolve_fetcher(def)` | Resolves an entry's `fetcher` to its function (string name → registry lookup; a function is used as-is). |
| `makac.resolve_pkg_dir(def, data_dir?)` | Where an entry's code lives: `<data_dir>/packages/<id>/`, or `with.path` for a `filesystem` package. |
| `makac.fetch_all(data_dir?)` | Fetches every listed package in file order into `<data_dir>/packages/<id>/`. |
| `makac.load_packages(data_dir?)` | Loads every listed package's `makac.lua` into the registries under `<id>:<name>`; sets `pkg_dirs` before each loads. No `packages.lua` → returns 0. |

Package-provided `lib/` code is require-able as `require("pkgs/<id>/a/b")` via a
searcher the prelude installs (maps to `<package root>/lib/a/b.lua`).

## Odin-side primitives (VM-baked)

These are C closures registered into `makac` before the prelude runs.

### `makac.exec(argv, opts?)`

Run a command directly (no shell), capturing stdout and stderr separately.

```lua
local res = makac.exec({ "git", "rev-parse", "HEAD" }, {
    chdir = "/tmp",          -- optional working directory
    env = { FOO = "bar" },   -- optional extra env, merged on top of makac's
    stdin = "data",          -- optional non-interactive stdin
    join = false,            -- optional: merge stderr into stdout (2>&1)
    timeout_s = 30,          -- optional: kill on overrun (host only)
    on_line = nil,           -- optional: function(line, stream), streamed
})
```

- `argv` must be a non-empty array of strings.
- Returns `{ code = int, stdout = string, stderr = string, timed_out = bool }`.
  `timed_out` is true iff `timeout_s` killed the command.
- A **non-zero exit code is data, not an error** — only a failure to spawn the
  program raises.
- With `join=true`, stderr shares stdout's descriptor: `res.stdout` holds the
  true interleaving and `res.stderr` comes back empty.
- `on_line(line, stream)` is called with each complete line as it arrives
  (`stream` is `"stdout"`/`"stderr"`, always `"stdout"` when joined); a
  raising callback aborts the command and raises.
- `timeout_s` on a remote-target `run` is not supported (raises); on the host
  it is supported.

### `makac.fs.*` — file system

All under the `makac.fs` table.

| Primitive | Returns / behavior |
| --- | --- |
| `makac.fs.mkdir_p(path)` | Create `path` and any missing parents. Existing dir is fine; raises on failure. |
| `makac.fs.listdir(path)` | Array of `{ name = string, is_dir = bool }`; `(nil, err)` when the directory cannot be read (not a raise — absence is data). |
| `makac.fs.read_file(path)` | The file contents as a string; `(nil, err)` when unreadable. |
| `makac.fs.write_file(path, data, opts?)` | Write `data` to `path` (truncating). `opts.atomic = true` writes to a sibling temp file first, then renames over the target (0600; a concurrent reader never sees a half-written file). Raises on failure. |
| `makac.fs.stat(path)` | `{ type = "file"\|"dir"\|"socket"\|"link"\|"other", size = int, mtime_ns = int }` (lstat), or `nil` when the path does not exist. |
| `makac.fs.mktemp_dir(prefix?)` | Create a fresh directory (mode 0700) in the system temp dir; caller removes it. Returns its path. |
| `makac.fs.mktemp_file(prefix?)` | Create a fresh empty file in the system temp dir; returns its path for the caller to fill and remove. |
| `makac.fs.sha256(path)` | Hex-encoded SHA256 of the file (streamed); `(nil, err)` for a missing/unreadable file. |
| `makac.fs.cwd()` | The current working directory. |
| `makac.fs.open_dir(path)` | A `Dir` handle with iteration/walk methods (used for recursive traversal). |

`makac.listdir(path)` is also registered flat (an alias of `makac.fs.listdir`).

### `makac.time.*` — time

| Primitive | Description |
| --- | --- |
| `makac.time.now()` | `CLOCK_MONOTONIC` in nanoseconds, as an integer. |
| `makac.time.sleep(ns)` | Sleep for `ns` nanoseconds (resumes on `EINTR`). `ns` must be non-negative and ≤ 10 years. |
| `makac.time.ns_per_us` / `ns_per_ms` / `ns_per_s` | Integer constants `1000` / `1_000_000` / `1_000_000_000`. |

### `makac.env.*` — environment and identity

| Primitive | Description |
| --- | --- |
| `makac.env.all()` | The whole process environment as `{ NAME = value, ... }`. |
| `makac.env.version()` | Two integers: `major, minor` (e.g. `0, 3`). Same pair `--version` prints; capability-pinning for workflows. |
| `makac.env.makac_path()` | Absolute, canonicalized path of the running `makac` binary (for re-invoking makac without trusting `$PATH`). |

There is deliberately **no** `set` counterpart: per-command environments belong
to `makac.exec`'s `env` option.

### Processes

| Primitive | Description |
| --- | --- |
| `makac.pid_alive(pid)` | `true` if the process `pid` exists, `false` if not. One `kill(pid, 0)` syscall; never raises. |
| `makac.spawn(argv, opts)` | Detach a long-lived child that outlives the run (stdio goes to **files**, never pipes; stdin is `/dev/null`). `opts = { stdout = <path>, stderr = <path>, chdir?, env? }` — `stdout`/`stderr` required. Returns a `proc` object: `proc.pid` (integer) and `proc:status()` → `"running"` or `{ code = int }` (waitpid `WNOHANG`; reaps once exited, then reports the cached result). There is no `:kill` and the object never kills on GC. |

### Downloads

| Primitive | Description |
| --- | --- |
| `makac.fetch(url, sha256?)` | Download `url` over HTTP(S) into a cache keyed by the URL, optionally verifying `sha256`; returns the on-disk cached path. Raises on failure (network, HTTP error, checksum mismatch). Cache: `<data_dir>/cache`. |
| `makac.download(url, sha256?, cache_dir?)` | Same as `makac.fetch`, with an optional explicit cache-directory override. |

Both raise on failure (e.g. `"checksum mismatch"`); a second fetch of the same
URL is served from cache (re-verified when a checksum is given — a corrupt
entry is dropped and re-fetched).

### `makac.json.*`

| Primitive | Description |
| --- | --- |
| `makac.json.dumps(value)` | Serialize a Lua value to a JSON string. Raises on unencodable values. |
| `makac.json.loads(string)` | Parse a JSON string into a Lua value. |

### Miscellaneous

| Primitive | Description |
| --- | --- |
| `makac.random_hex(n)` | `n` random lowercase hex chars (n must be positive). |
| `makac.ssh_open(name, spec)` | Low-level SSH session: `{ host, user, port?, options? }` → session with `run`/`put`/`get`/`close` methods and `name`/`port` fields. Backs `makac.new_ssh_target`; state (including the generated ssh config with `ControlMaster`/`ControlPath`/`ControlPersist`) lives under `<data_dir>/targets/<name>/`. |
| `makac.qmp_open(...)` | QEMU Machine Protocol client (used by the QEMU package; plain tables on the Lua side — the JSON wire format is never part of the surface). |

## The full register order (for reference)

The VM registers, in order: QMP, time, json, fs, env, process (`pid_alive`),
spawn, random, then the embedded prelude, then exposes `makac.data_dir`. The
prelude defines `step`, the built-in actions (`shell`, `facts`), the fact
finders (`os`, `env`), the target wrappers, the fetchers (`fetchurl`,
`fetchgit`, `filesystem`), the package loader, and the `pkgs/` searcher.
