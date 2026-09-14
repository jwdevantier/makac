# QMP: the QEMU Machine Protocol client

QMP is QEMU's control protocol: line-oriented JSON over a unix socket (or
TCP). Commands — `{"execute": ...}` lines — are answered by `{"return":...}`
or `{"error":...}` replies; alongside them QEMU pushes asynchronous *events*
(`DEVICE_DELETED`, `RESET`, ...) whenever they fire. makac ships a client for
it in two layers:

* `./qmp` — the Odin package: connection, handshake, framing, deadlines, and
  the event buffer. Transport-agnostic: unix socket, TCP, or anything that
  can produce a pollable fd via a `Transport` vtable.
* `makac.qmp_open` — the Lua binding (`vm/qmp.odin`): an object-style client
  userdata over the package. Lua writes and reads plain tables throughout;
  the JSON wire format is never part of the surface.

## The client object

```lua
local q = makac.qmp_open("/run/vm/qmp.socket")          -- unix socket path
local q = makac.qmp_open({ tcp = "127.0.0.1:4444" })    -- tcp endpoint
local q = makac.qmp_open({ socket = path, timeout_s = 5 })
```

One client object holds exactly one connection, opened and handshaked
(greeting + `qmp_capabilities`) by `qmp_open` itself; `timeout_s` bounds the
whole connect+handshake (default 5). QEMU delivers events only to
connections that exist when they fire — nothing is replayed — so to observe
an event, arrange to poll after whatever raises it.

`q:close()` tears the connection down and frees the client's memory; it is
idempotent, and `__gc` is the backstop for clients that leak. Every method
raises on a closed client.

## send

```lua
local res = q:send(commands, { timeout_s = }?)
```

`commands` is an array of `{ execute = <string>, arguments = <table>? }`
sent in array order — hotplug sequences depend on this. `results` comes
back the same length, same order, one entry per command:

* `{ ["return"] = <decoded payload> }` on success, or
* `{ error = { class = <string>, desc = <string> } }` on a QMP error.

A QMP error reply is DATA (a result entry); transport failures — connection
lost, write failed, protocol error — RAISE. A `timeout_s` (default 5)
elapsing means the VM is unresponsive, and raises too. JSON numbers decode
with integers staying integers.

Sending a command clears the event buffer first: a new command is the
declaration that events predating it are not of interest. In a
multi-command send each command retires the events that preceded it; events
arriving while a command is in flight are buffered, to be read with
`poll`/`events` once the send returns.

## The event buffer

Events drained from the connection accumulate in a per-client buffer until
discarded. Three methods manage it; events are read from the buffer and
removed from it — never handed out as copies:

```lua
q:poll({ timeout_s = }?) -> bool
```

Drains whatever the connection currently has into the buffer — default 0,
no wait; a timeout is not an error — and returns whether any events arrived
during this call.

```lua
q:events(n?) -> events
```

The first `n` buffered events — all of them when `n` is omitted — as
`{ name = <string>, data = <table>?, timestamp = <table>? }` (`data` /
`timestamp` only when the event carries them). They STAY buffered: reading
does not consume. Raises when `n` exceeds the buffered count.

```lua
q:consume(n)
```

Drops the `n` oldest buffered events — the ones the caller has finished
treating. Raises when `n` exceeds the buffered count.

The pattern — raise a condition, then witness it:

```lua
q:send({ { execute = "device_del", arguments = { id = "ns.test" } } })
if q:poll({ timeout_s = 10 }) then
  local evs = q:events()
  -- ... treat them ...
  q:consume(#evs)
end
```

(A following `send` would clear the buffer anyway; `consume` is how a caller
discards treated events when it does not intend to send next.)

## The Odin package (`./qmp`)

The Lua binding facilitates use of the underlying Odin code.

* A `Client` holds the per-connection state — the socket fd (via a
  `Transport`), the read buffer, the event queue, the allocator owning all
  client memory, an optional `Logger` proc for protocol tracing. It is
  synchronous and single-threaded: do not share across threads.
* `connect` / `connect_tcp` / `connect_transport` establish and handshake,
  bounded by a timeout. `unix_transport` / `tcp_transport` build the
  built-in transports; a custom backend is a `Transport` vtable
  (`connect` / `close`) — anything that yields a pollable fd works.
* `send(c, command, timeout) -> (Reply, Error)` — writes one command line
  and reads until its reply or the deadline. `Reply` carries `ok`, the raw
  `return_json`, or the QMP error `class`/`desc`. Clears the event buffer
  first; a `.Timeout` means the VM is unresponsive.
* `poll(c, timeout) -> (drained: bool, Error)` — drains available messages
  into the buffer; a timeout is benign (`.None`, `drained == false`).
* The buffer is the `Client.events` field itself — a `[dynamic]Event`,
  oldest first, each entry a `name` plus the `raw` JSON line. There is no
  accessor proc: read the slice directly.
* `consume(c, n)` — drops the `n` oldest entries (clamped to the buffered
  count).
* `close(c)` frees everything; `connected(c)` reports liveness.

Every call is deadline-bounded, so a hung QEMU never blocks the caller
forever. Memory: the client owns the buffered events' strings and the last
reply's strings; they are freed when consumed or cleared (`send`, `close`).
Do not retain them across those calls — clone what you need first.

## Testing

* `qmp_test/` — the package driven against `fake_qmp.py` over both unix and
  tcp transports (`qmp_test/run_tests.sh`), leak-checked with a tracking
  allocator.
* The `vm` suite — the binding driven against a fake in-process QMP server
  (`odin test vm`): handshake, send marshaling and error shaping, the
  event-buffer discipline, lifecycle.
