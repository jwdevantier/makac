# Feasibility notes

What each `design2/*.md` doc needs from makac. Status: everything catalogued
here is implemented and tested — the "Remaining primitives" at the end landed
with the extended stdlib (`stdlib.md`), and the `qemu` package exists
(`extras/makac-qemu/`, exercised by `qemu_test/`).

## Already present

* `makac.exec(argv[, opts])` — synchronous exec with captured output. Covers
  `qemu-img`, `genisoimage`, `kill -0` probes, force kills.
* `makac.download(url, sha256, cache_dir?)` — sha256-verified,
  content-cached download. Covers `cloud-init` stage 1 and `sources`.
* `./ssh` + `makac.new_ssh_target(name, spec)` — the VM ssh target in `vm.md`
  is a direct call on it. (The primitive layer underneath is a session object:
  `makac.ssh_open(name, { host, user, port?, options? })` returns userdata with
  `:run`/`:put`/`:get`/`:close` methods; `new_ssh_target` wraps one session
  into a remote target.)
* `./qmp` — QMP client: connect/handshake, command/reply, event drain,
  unix & tcp transports. The buffer-model adjustment described below (poll
  returns the events it drained, which stay buffered; `consume(c, n)` drops
  the n oldest) is implemented, as is the Lua binding.
* `makac.listdir` — state-dir walks.

## The QMP binding

**Implemented** (`vm/qmp.odin`; covered by the `vm` test suite against a fake
in-process QMP server, and by `qmp_test/` against `fake_qmp.py` over unix and
tcp transports).

Bindings over the `./qmp` client, one persistent connection per VM per run
(`qmp.md`, "The connection model"). Object-style, like the ssh session
primitive: `makac.qmp_open` returns a client userdata whose methods do the
work:

```
local c = makac.qmp_open("/run/vm/qmp.socket")                 -- unix path, or
c = makac.qmp_open({ socket = path, timeout_s = 5 })           -- spec form, or
c = makac.qmp_open({ tcp = "127.0.0.1:4444" })                -- tcp endpoint

c:send(commands, { timeout_s = }?) -> results   -- one entry per command,
    -- in order: { ["return"] = <decoded payload> } on success or
    -- { error = { class =, desc = } } on QMP error. QMP errors are DATA;
    -- transport failures (connect lost, timeout) RAISE.
c:poll({ timeout_s = }?) -> events              -- events drained during THIS
    -- call ({ name =, data? =, timestamp? = }); they stay buffered
c:consume(n)   -- drop the n oldest buffered events; raises when n exceeds the
    -- buffered count
c:close()      -- idempotent; __gc is the backstop for leaked clients
```

* `commands` is an array of `{ execute = <string>, arguments = <table>? }`,
  sent in order. Send clears the event buffer first: a new command retires
  prior events (qmp.md).
* `core:encoding/json` marshals command tables and unmarshals replies and
  events; Lua receives plain tables throughout, the wire format is never part
  of the surface. An empty `arguments = {}` marshals to `{}`; tables mixing
  array and non-array keys are a spec error.
* The `qemu:qmp/send|poll|consume` actions are argument validation, handle
  registry and error shaping around these methods. The `pkgs:qemu/qmp`
  library needs nothing from Odin: its constructors are pure table builders.
* Connection teardown: the package's handle registry closes its client when
  the handle is closed (`qemu:vm` stop, `close_all_targets` at run end);
  anything leaked past that is closed by the client's `__gc` at VM teardown.
  Nothing VM-side survives the run end except the process itself and its
  files.

## Detached launch

`makac.exec` waits for exit; a launched VM must not. Mirrors qqmgr's
`cmd/start.go`: a `makac.spawn(argv, { stdout =, stderr = })` primitive
forks the child with stdio redirected to the per-VM log files (never pipes),
returns a process object whose `:status()` probes early exit
(waitpid/WNOHANG); the launch window polls for the QMP socket while watching
for early exit — failure quotes the stderr log (`vm.md`, "launch errors are
step failures"), socket appearance is success. The run may then exit with
the VM behind it: the orphan is inherited and reaped by init. See "Launching
long-lived processes" in `stdlib.md` for the full account. No `-daemonize`:
it would forbid stdio chardevs/monitors and buys nothing we do not already
own in the probe loop.

## Remaining primitives *(status: all landed)*

Settled by `stdlib.md` (namespaced, htt-style: language gap-fillers under
`makac.fs`/`makac.time`/`makac.json`/`makac.env`; orchestrator verbs stay
flat): `makac.time.sleep` (poll-loop sleep), `makac.time.now` (monotonic ns;
supersedes the earlier `os.time()` suggestion — wall clock is wrong for
timeouts), `makac.pid_alive` (replaces noisy `kill -0` shell-outs),
`makac.fs.sha256` (manifest hashing, drawing on the downloader's
`file_matches_sha256`), plus the filesystem basics Lua lacks (`fs.mkdir_p`,
`fs.stat`, `fs.read_file`, `fs.write_file`, `fs.mktemp_*`), `env.all`,
`fs.path_join`, `fs.cwd`, `json.dumps`/`json.loads`, `random_hex`.

| need                        | resolution                                    |
|-----------------------------|-----------------------------------------------|
| spawn without waiting       | `makac.spawn` + `:status()` (`stdlib.md`)      |
| sleep in poll loops         | `makac.time.sleep(ns)` (`stdlib.md`)           |
| timeouts                    | `makac.time.now()` — monotonic (`stdlib.md`)   |
| pid liveness                | `makac.pid_alive(pid)` (`stdlib.md`)           |
| manifest hashing            | `makac.fs.sha256(path)` (`stdlib.md`)          |
| mkdir / stat / slurp / ...  | `stdlib.md`, the `makac.fs` sections           |

## Notes on specific docs

* State outliving the runner (`handle.md`, `main.md`): the package's handle
  registry holds each VM's QMP client object; closing the registry (via the
  `close_all_targets` run-end hook) closes the connections, and the client
  `__gc` catches anything left — nothing VM-side survives the run end except
  the process itself and its files.
* `images.md` stage 5 (wait for power-off): the VM outlives its launch
  command, so the wait is a pidfile liveness poll + QMP `query-status` loop,
  bounded by `timeout_s`.
* `snapshots.md`: capture is QMP `snapshot-save` (guest quiesced, state
  baked into the image under a tag); resume appends `-loadvm <tag>` to the
  launch command line. Requires snapshot-capable (qcow2) writable devices —
  which the overlay disks of `vm.md` are.
