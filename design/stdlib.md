# The extended stdlib

Lua's standard library is deliberately minimal (it targets ANSI C), and a
workflow/orchestration DSL runs into its edges quickly. This document defines
makac's extended stdlib: small Odin-backed primitives exposed under `makac`,
in the spirit of the better parts of the Ruby stdlib (`ENV`, `Dir.mktmpdir`,
`File.*`, `SecureRandom`, `Process.clock_gettime(CLOCK_MONOTONIC)`) and the
`htt.*` Lua API of sibling tooling, with implementations drawn from Odin's
core libraries.

Taste rules for what gets in:

* The primitive must be something Lua genuinely cannot do (create a
  directory, sleep, list its own environment) or cannot do *safely*
  (monotonic timing, atomic file write, pid liveness).
* Convenience wrappers over Lua that works fine (`os.getenv`, `io.open`) stay
  out; the stdlib augments, it does not re-skin.
* Each entry names at least one caller in the design docs — nothing speculative.

## Status — what exists, what doesn't

*Read this first.* Each section header below also carries a
`*(status: …)*` tag; update both places when landing work.

| area | status | notes |
|---|---|---|
| `makac.fs` — paths (`path` type) | **done** | third userdata metatable `makac.path`; coercion pass: every fs function takes string-or-path via `check_path_string`; mktemp_*/null_file return paths |
| `makac.fs` — directory handles (`Dir`) | **done** | the `walk` iterator is an eager depth-first snapshot, so mid-loop tree mutation is safe; sub guard rejects absolute/`..` |
| `makac.fs` — directories, files, temp, hashing | done | thin `core:os` wrappers; `write_file{atomic}` is temp+rename; `sha256` streams via `core:crypto/hash` (`hash_file_by_name`, `load_at_once = false`) like the downloader's `hash_file`; flat `makac.listdir` EXISTS, moved to `makac.fs.listdir` with the flat name kept as alias |
| `makac.env` (`all`, `version`, `makac_path`) | **done** | `core:os.environ` split at first `=`; `version` reads build-time constants `vm.VERSION_MAJOR/MINOR` (0.3), same pair as `makac --version`; `makac_path` is `os.get_executable_path` (`/proc/self/exe`) as a path |
| `makac.time` (`sleep`, `now`, `ns_per_*`) | **done** | `clock_gettime`/`nanosleep` plumbing |
| `makac.json` (`dumps`, `loads`) | **done** | converters already written: hoist `_lua_to_json`/`_push_json` out of `vm/qmp.odin`, register two functions |
| `makac.spawn` (+`:status`) | **done** | detached fork via `core:sys/posix`; stdio to files only (append), stdin `/dev/null`; env merges over ours; `status()` reaps via waitpid WNOHANG and caches; no `:kill`, never kills on GC; new userdata metatable `makac.proc`; see `launch.md` |
| `makac.pid_alive` | **done** | one `kill(pid, 0)`; `false` on ESRCH, `true` on EPERM, `true` on success; never raises |
| `makac.random_hex` | **done** | `core:crypto.rand_bytes` + `encoding/hex` (odd-n truncation) |
| `makac.exec` opts: `join`, `timeout_s`, `on_line` | **done** | incl. blocking-poll drain loop (no busy spin); shell action passes `with.join`/`timeout_s`/`on_line` (remote: `join` via `2>&1`, the others raise "not supported on remote targets yet") |
| `makac.qmp_open` client object | **done** | `feasibility.md`, "The QMP binding" |
| `makac._ssh_open` session object | **done** | wrapped by `makac.new_ssh_target(name, spec)` (prelude) |

Suggested landing order (dependency-driven):

1. **Plumbing batch**: `time`, `env`, `pid_alive`, `random_hex`, `json`
   (hoist), flat fs functions (`mkdir_p`, `stat`, `read_file`/`write_file`,
   `mktemp_*`, `path_join`, `fs.listdir` move). Independent, temp-dir
   testable.
2. **Objects batch**: `fs.path`, then `fs.Dir`, then `spawn` — `spawn`
   unblocks `launch.md`'s start sequence, the first real consumer.
3. Then the `qemu` package can start; everything it leans on exists.

Implementation notes that earned their keep (don't relearn):

* `lua.L_error` longjmps — Odin defers don't run on raise paths; clean up
  explicitly before raising.
* Odin defers are BLOCK-scoped; a `defer` inside an `if`/bare block runs when
  the block ends. (A pipe fd closed "deferred" inside a block is closed
  *before* the spawn that was supposed to use it.)
* No closure capture in proc literals: thread state through a
  userdata/bridge struct (see `On_Line_State`/`_on_line_bridge` in
  `vm/exec.odin`).
* Run the test suite with a wall-clock `timeout` and purge orphaned test
  binaries after failures (`timeout` kills the shell, not the process tree).

## Organization

Two layers, on purpose:

* **Flat `makac.*`** stays the *orchestrator* vocabulary: `exec`, `spawn`,
  `download`, `pid_alive`, `_ssh_open`, `qmp_open` — things only makac does.
* **Submodules** hold the *language gap-fillers* — what Lua-the-language
  should have had (the htt precedent: `htt.fs`, `htt.time`, `htt.json`,
  `htt.env`): `makac.fs`, `makac.time`, `makac.json`, `makac.env`.

## Conventions

Same as the existing `makac.*` primitives (`exec`, `download`, `listdir`,
`_ssh_open`, `qmp_open`), plus:

* **Errors raise** — bad arguments, exhausted resources, failed syscalls that
  the caller cannot reasonably ignore. **Absence is not an error**: where a
  missing thing is a legitimate answer, the function returns `nil` (plus an
  error message for the ambiguous cases) instead — the `listdir` precedent.
* **Time is nanoseconds**, always: one integer unit, `ns_per_*` constants
  for readability, no `_ms`-suffixed variants (Lua 5.4 integers are 64-bit;
  nanoseconds since boot fit for centuries).
* **Paths** are a real type (the htt precedent), not bare strings. A `path`
  is a userdata produced by `fs.path`; every path-taking `fs` function
  accepts a string *or* a path (paths coerce through `__tostring`), and
  path-returning functions return paths. Relative arguments resolve against
  the CWD makac was invoked from (like `exec`'s `chdir` default);
  `fs.cwd`-derived values are absolute.

## What Lua already has — do not re-add

* `os.getenv(name)` reads one variable. `package.config:sub(1,1)` is the
  path separator (`/` on every platform makac supports).
* `io.open`/`io.lines` read files; `os.remove`/`os.rename` delete and move.
* `os.time()`/`os.date()` are the *wall* clock — fine for timestamps, wrong
  for timeouts (use `time.now` below; an NTP step mid-wait must not break a
  bound).

## `makac.env` *(status: done)*

```lua
makac.env.all() -> { NAME = value, ... }
makac.env.version() -> major, minor        -- integers; see "Versioning" below
makac.env.makac_path() -> path             -- absolute path of the running binary
```

`all` is the whole process environment as a table (Ruby: `ENV.each`; Odin:
`core:os2.environment`). Single reads stay `os.getenv`. There is deliberately
no `set` counterpart: per-command environments belong to `exec`'s `env`
option; mutating process-wide state mid-workflow is a footgun nothing needs.

`version` is the htt scheme, verbatim: **major** increments when *existing*
APIs change incompatibly, **minor** increments when APIs are added. The point
is capability pinning — a workflow depending on newer features fails early
and clearly:

```lua
local major, minor = makac.env.version()
if minor < 3 then error("workflow needs makac >= 0.3 (the qemu package)") end
```

The version is a build-time constant in the Odin source (single source of
truth; a `makac --version` CLI flag prints the same pair). While major is
0, minor bumps may include incompatible changes — the discipline starts
at 1.0.

`makac_path` is the absolute, canonicalized path of the running makac binary
(`/proc/self/exe` on Linux and kin; Odin `core:os.get_executable_path`) as a
`path` value. For re-invoking makac in an isolated process — htt uses its
equivalent to run a second script under a fresh interpreter; likewise, a
workflow can spawn `makac run other_workflow.lua` without trusting `$PATH`.

## `makac.time` *(status: done)*

```lua
makac.time.sleep(ns)            -- no return; the poll-loop primitive Lua lacks
makac.time.now() -> integer     -- MONOTONIC nanoseconds, for timeout arithmetic
makac.time.ns_per_us            -- constants; write 50 * makac.time.ns_per_ms
makac.time.ns_per_ms
makac.time.ns_per_s
```

`now` is a monotonic clock (Ruby: `Process.clock_gettime(CLOCK_MONOTONIC)`;
Odin: `core:time` / `CLOCK_MONOTONIC`), *not* wall time — all "deadline by"
comparisons in the design docs (`wait_ssh`, image stage 5's power-off wait,
serial-log waits) are `now() + timeout * ns_per_s` arithmetic, never
`os.time()`. *Callers*: every poll loop in `vm.md` and `images.md`; see
`launch.md` for the loops in context.

## `makac.fs` — paths *(status: DONE)*

```lua
makac.fs.sep                          -- constant: the platform separator ("/")
makac.fs.path(s) -> path              -- constructor; s may be string or path
makac.fs.path_join(a, b, ...) -> path -- variadic; empty elements dropped
makac.fs.null_file() -> path          -- "/dev/null" (spawn's stdin default)
```

A `path` is a userdata (same object discipline as `_ssh_open`/`qmp_open`:
metatable, no resources to close, `__gc` frees nothing Lua doesn't already
manage). Its surface is deliberately minimal:

```lua
tostring(p)    -> string   -- the path as a string — THE escape hatch:
                           -- anything not on the object is done on the string
p:dirname()    -> path     -- parent directory ("/a/b/c" -> "/a/b")
p:basename()   -> string   -- final element ("/a/b/c" -> "c")
p:join(x, ...) -> path     -- == fs.path_join(p, x, ...)
```

No `ext`, no `absolute`/`clean` — added on evidence, not prospectively.
Implementations are one call each into `core:path/filepath`
(`join`/`dir`/`base`); `fs.path` cleans its argument on construction.
*Callers*: `handle.md`'s run-dir derivation, the run-dir file paths of
`vm.md`, log tails in `launch.md`.

## `makac.fs` — directory handles (`Dir`) *(status: done)*

(The htt precedent: an *anchored* directory handle — open a root once, then
work by relative subpath. This is the shape makac's state model wants:
`.makac/qemu/<name>/`, `.makac/qemu/img/<name>/` are exactly "a root you do
repeated relative work under".)

```lua
makac.fs.cwd() -> Dir                 -- the directory makac was invoked in
makac.fs.open_dir(path|path_str) -> Dir   -- raises unless it exists and is a dir
```

A `Dir` holds the canonical absolute path of the root (resolved at
construction), nothing else — no fd, nothing to close; every operation takes
an optional `sub` path RELATIVE to the root, validated (must be relative;
no `..`), and errors raise per makac convention (htt returns `(res, err)`
pairs; makac raises, reserving plain returns for absence answers):

```lua
d:path() -> path                -- the canonical absolute root
d:exists(sub?) -> bool          -- plain boolean: absence is an answer
d:touch(sub)                    -- create an empty file; raises
d:make_path(sub)                -- mkdir -p relative to root; raises
d:open_dir(sub) -> Dir          -- descend into a subdirectory handle
d:parent() -> Dir               -- the root's parent
d:list() -> { { name =, type = }, ... }   -- one level; type: see fs.stat
d:walk() -> iterator            -- recursive, generic-for:
                                --   for sub, type in d:walk() do ... end
d:remove(sub?)                  -- remove sub (recursive for directories);
                                -- omit sub to remove the root itself
```

* `exists`/`touch`/`remove` with `sub` omitted operate on the root itself;
  after `d:remove()`, the handle is stale (operations keep working on the
  now-absent path and report accordingly — `exists()` says `false`).
* `list` returns an array of entries like `listdir` (name + `type`, the same
  vocabulary as `fs.stat`); `walk` is a depth-first iterator yielding
  `(sub, type)` pairs — directories are yielded too, before their contents.
* Simplification, documented: htt's `Dir` is fd-anchored (capability-style,
  race-proof against symlink swaps); makac's is *path*-anchored with a
  subpath guard — the threat model is a local workflow tool, not an
  adversarial filesystem. Rethink only if a caller ever faces one.

*Callers*: `handle.md`'s probe (`d:exists("pid")`), `vm.md`'s
`cleanup_runtime_files` (literally `fs.open_dir(h.run_dir):remove()`), stage
dir management in `images.md`, any package code that lives under a well-known
root. The flat `fs.mkdir_p`/`fs.listdir` remain as cwd-anchored conveniences
for one-off absolute paths; repeated relative work under a root is what `Dir`
is FOR.

## `makac.fs` — directories *(status: done)*

```lua
makac.fs.listdir(path) -> { { name =, is_dir = }, ... } | nil, err  -- moved here
makac.fs.mkdir_p(path)                   -- parents as needed; existing dir is fine
```

`mkdir_p` fills the most basic gap: stock Lua cannot create a directory at
all. `listdir` keeps its existing entry shape (and the `nil, err`
absence-is-not-an-error convention); the flat `makac.listdir` predates the
submodules — the entry point moves here, with the flat name kept as an alias
for the prelude's own use. *Callers*: run-dir / stage-dir creation in `vm.md`
and `images.md`, package enumeration in the prelude.

## `makac.fs` — regular files and temp entries *(status: done)*

```lua
makac.fs.read_file(path) -> string | nil, err
makac.fs.write_file(path, data, { atomic = }?)
makac.fs.stat(path)  -> { type =, size =, mtime_ns = } | nil
makac.fs.mktemp_dir(prefix?) -> path     -- created, mode 0700; caller removes
makac.fs.mktemp_file(prefix?) -> path    -- created empty; io.open for writing
makac.fs.symlink(target, link)           -- create/replace a symlink at `link`
```

* **`read_file`** — one-call slurp, `nil, err` on failure (the `listdir`
  precedent).
* **`write_file`** — with `atomic = true` writes a sibling temp file and
  renames over the target: a concurrent `makac run` attaching to a named VM
  must never observe a half-written `invocation` or manifest (`handle.md`'s
  re-derivation across runs is precisely concurrent readers of these files).
* **`stat`** — existence plus kind, in one syscall: `type` is
  `"file" | "dir" | "socket" | "link" | "other"`; `nil` when the path does
  not exist (absence is an answer). `io.open(p) == nil` can't tell a missing
  pid file from a present socket — `handle.md`'s probe needs the distinction.
* **`mktemp_*`** — rooted in the system temp dir: these are by definition
  ephemeral (state that must survive the run lives under `.makac/`). Raise on
  failure; `prefix` is incorporated into the name so temp entries are
  recognizable. (Lua's `os.tmpname` hands out a bare name without creating
  anything — race-prone and file-only. Ruby: `Dir.mktmpdir`, `Tempfile`;
  Odin: `core:os.make_directory_temp`.) *Callers*: stage scratch in
  `images.md`; anywhere a transfer is staged.
* **`symlink`** — create/replace a link: any existing entry at `link` is
  removed first (a non-empty directory makes `remove` fail, so real content
  is never clobbered). Added for the LuaLS alias tree — `<data>/pkgs/<id>` ->
  `<code>/lib` (design/luacats.md). *Caller*: `makac._luals_setup`.

## `makac.fs` — hashing *(status: done)*

```lua
makac.fs.sha256(path) -> hex_string | nil, err
```

Streams the file (image inputs can be gigabytes — there is deliberately no
string-taking variant to encourage loading one into Lua), hex-encoded
result. Returns `nil, err` for a missing/unreadable file: to a manifest,
"input file gone" is data (the stage rebuilds), not an exception. The
downloader already has `file_matches_sha256` to draw on. *Caller*:
`images.md` manifests.

## `makac.json` *(status: done)*

```lua
makac.json.dumps(value)  -> string       -- raises on unencodable values
makac.json.loads(string) -> value        -- raises on malformed JSON
```

(`dumps`/`loads` by Python/htt convention.) The same converters the
`qmp_open` client binding already runs on — hoisted to shared helpers, not
added twice — so the rules are identical to `qmp:send`'s arguments: tables
are objects unless every key is an integer in 1..n (then arrays); an empty
table is `{}`; functions/userdata/mixed-key tables raise. Decoding keeps
integers as integers. *Callers*: manifests in `images.md` (which hash
structured spec tables), the `invocation` file format if it ever wants to be
structured, and any workflow persisting state under `.makac/`.

## Processes (flat — orchestrator vocabulary) *(status: done — `pid_alive`, `spawn`, `exec` incl. join/timeout_s/on_line)*

```lua
makac.pid_alive(pid) -> bool
makac.spawn(argv, { stdout = <path>, stderr = <path>, chdir?, env? }) -> proc
  proc.pid                    -> integer
  proc:status() -> "running" | { code = }   -- waitpid(WNOHANG); reaps once exited
```

(`makac.exec` is the synchronous sibling and already exists: captured
stdout/stderr separately, exit code as data, plus `join`, `timeout_s` and an
`on_line(line, stream)` streaming callback — its drain loop is a blocking
poll, not a busy spin. The `shell` action passes `join`/`timeout_s`/`on_line`
through; see design/action_shell.md.)

`pid_alive` is one `kill(pid, 0)` syscall; `false` for ESRCH, `true` for
EPERM (the process exists even if it isn't ours) — the two cases shelling
out to `kill -0` cannot tell apart without stderr parsing. Never raises.
*Caller*: `handle.md`'s up/down probe, `vm.md`'s shutdown wait, `images.md`
stage 5.

`spawn` forks a child whose lifetime nobody manages, for processes that must
outlive the run: stdio goes to *files*, never pipes (a pipe reader would
block for the child's whole lifetime — the one hard rule of detached
spawning); stdin is `/dev/null`; `p.pid` and `p:status()` observe the child;
there is deliberately no `:kill` (`exec {"kill", ...}` covers it) and the
object never kills on GC. See "Launching long-lived processes" below and
`launch.md` for the VM start/stop choreography built on it.

## Launching long-lived processes (QEMU) *(status: done — `spawn` per launch.md)*

*Resolved: the `spawn` primitive above, mirroring qqmgr's `cmd/start.go`; no
`-daemonize`.* qqmgr (the Go program this package re-implements) starts QEMU
by plain fork: stdout/stderr point at the per-VM log *files*, stderr
additionally teed into a capture buffer; the parent races the child's exit
against a grace window: an *early exit* means launch failure and the
captured stderr is quoted; the *QMP socket appearing* means success. The
qqmgr process then exits and the orphaned VM is reparented — this is a CLI
doing this, not the qqmgr daemon, and it works fine in practice (an orphan
is inherited and reaped by init; the worst case is a cosmetic zombie window
when a VM dies mid-run).

makac does exactly that with one refinement: qqmgr sleeps the full 5 seconds
before *checking* (every start pays the stall); the window in makac is a
poll loop — same detections, latency only when warranted (`vm.md`: "a socket
that never appears within a short launch window is a step failure").
`launch.md` has the annotated pseudo-Lua of the full start/stop sequences.

(`-daemonize` remains a footgun we decline: it forbids stdio chardevs /
monitors outright and would move failure detection inside QEMU's own
contract — we already own the probe loop, which needs no QEMU-side
concessions.)

## Misc (flat) *(status: done — `random_hex`)*

```lua
makac.random_hex(n) -> string   -- n hex chars from core:crypto's CSPRNG
```

Covers `images.md`'s "generate an instance id" without shelling out to
`uuidgen` (Ruby: `SecureRandom.hex`).

## Deliberately not in

* `env.set` — see `makac.env`.
* Globbing — `fs.listdir` + Lua patterns covers it.
* base64 — shell out; rare.
* `which()` — `exec` + `$PATH` covers it.
* `chmod`/`readlink` — deferred until a concrete caller exists.
* `sleep_ms`/`now_ms` and other unit-suffixed time variants — one unit
  (ns), `ns_per_*` constants.

## Implementation notes

* All of these are thin: each maps to one Odin core call (`core:os`,
  `core:os2`, `core:path/filepath`, `core:time`, `core:crypto`,
  `core:sys/posix`) wrapped in the existing `register()` plumbing — with one
  the qmp binding and `json.dumps`/`json.loads` cannot drift apart. The
  submodule tables (`makac.fs`, `makac.time`, `makac.json`, `makac.env`) are
  created in the same registration pass; `path` and `Dir` values add two
  userdata metatables ("makac.path", "makac.fs.Dir") alongside "makac.ssh"
  and "makac.qmp" — both resource-free, so their `__gc` is trivial.
* This doc settles the "Remaining primitives" table of `feasibility.md`:
  `time.sleep` *is* the sleep resolution, `pid_alive` replaces the noisy
  `kill -0` shell-out, `fs.sha256` is the manifest hashing, and `time.now`
  supersedes its "timeouts: `os.time()`" row (wall clock, rejected above).
