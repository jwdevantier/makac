<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Makac API

The `makac.*` primitives baked into the VM — registered from Odin before the
embedded prelude runs. For the workflow surface built on top of them (`step`,
targets, registries), see [The workflow DSL](workflow-dsl.md).

## `makac.exec(argv, opts?)`

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

## `makac.fs.*` — file system

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
| `makac.fs.cwd()` | A `Dir` handle for makac's current working directory. |
| `makac.fs.open_dir(path)` | A `Dir` handle at `path` (must exist and be a directory; else raises). |
| `makac.fs.path(s)` | Construct a `path` value from a string (or another path). |
| `makac.fs.path_join(a, b, ...)` | Join elements into a `path` (empty elements dropped). |
| `makac.fs.null_file()` | The `/dev/null` path. |
| `makac.fs.sep` | The platform path separator (`"/"`). |
| `makac.fs.symlink(target, link)` | Create (or replace) a symlink at `link` pointing at `target`; an existing entry is removed first (a non-empty directory makes that fail, so real content is not clobbered). |

`makac.listdir(path)` is also registered flat (an alias of `makac.fs.listdir`).

A `path` is a value, not a bare string: every `makac.fs` function takes a
string or a `path`, and the path-returning ones (`path`, `path_join`,
`null_file`, `mktemp_*`, `Dir:path()`) hand back a `path`. It carries
`dirname()` / `basename()` / `join(...)`, and `tostring(p)` yields the string.
A `Dir` offers `path`, `exists`, `touch`, `make_path`, `open_dir`, `parent`,
`list`, `walk` and `remove` (relative `sub` paths; `remove` is recursive).

## `makac.time.*` — time

| Primitive | Description |
| --- | --- |
| `makac.time.now()` | `CLOCK_MONOTONIC` in nanoseconds, as an integer. |
| `makac.time.sleep(ns)` | Sleep for `ns` nanoseconds (resumes on `EINTR`). `ns` must be non-negative and ≤ 10 years. |
| `makac.time.ns_per_us` / `ns_per_ms` / `ns_per_s` | Integer constants `1000` / `1_000_000` / `1_000_000_000`. |

## `makac.env.*` — environment and identity

| Primitive | Description |
| --- | --- |
| `makac.env.all()` | The whole process environment as `{ NAME = value, ... }`. |
| `makac.env.version()` | Two integers: `major, minor` (e.g. `0, 3`). Same pair `--version` prints; capability-pinning for workflows. |
| `makac.env.makac_path()` | Absolute, canonicalized path of the running `makac` binary (for re-invoking makac without trusting `$PATH`). |

There is deliberately **no** `set` counterpart: per-command environments belong
to `makac.exec`'s `env` option.

## Processes

| Primitive | Description |
| --- | --- |
| `makac.pid_alive(pid)` | `true` if the process `pid` exists, `false` if not. One `kill(pid, 0)` syscall; never raises. |
| `makac.spawn(argv, opts)` | Detach a long-lived child that outlives the run (stdio goes to **files**, never pipes; stdin is `/dev/null`). `opts = { stdout = <path>, stderr = <path>, chdir?, env? }` — `stdout`/`stderr` required. Returns a `proc` object: `proc.pid` (integer) and `proc:status()` → `"running"` or `{ code = int }` (waitpid `WNOHANG`; reaps once exited, then reports the cached result). There is no `:kill` and the object never kills on GC. |

## Downloads

| Primitive | Description |
| --- | --- |
| `makac.download(url, sha256?, cache_dir?)` | Download `url` over HTTP(S) into a cache keyed by the URL, optionally verifying `sha256`; returns the on-disk cached path. `cache_dir` defaults to `<data_dir>/cache`. Raises on failure (network, HTTP error, checksum mismatch). |

It raises on failure (e.g. `"checksum mismatch"`); a second fetch of the same
URL is served from cache (re-verified when a checksum is given — a corrupt
entry is dropped and re-fetched).

## `makac.json.*`

| Primitive | Description |
| --- | --- |
| `makac.json.dumps(value)` | Serialize a Lua value to a JSON string. Raises on unencodable values. |
| `makac.json.loads(string)` | Parse a JSON string into a Lua value. |

## Miscellaneous

| Primitive | Description |
| --- | --- |
| `makac.sha256(s)` | Lowercase SHA256 hex digest of a (possibly NUL-containing) string; used by fetcher `key` methods. |
| `makac.random_hex(n)` | `n` random lowercase hex chars (n must be positive). |
| `makac.qmp_open(...)` | QEMU Machine Protocol client (used by the QEMU package; plain tables on the Lua side — the JSON wire format is never part of the surface). |
