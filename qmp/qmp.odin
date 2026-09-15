// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// qmp - A synchronous, single-threaded QEMU Management Protocol (QMP) client.
//
// This package talks to a QEMU instance over a Unix domain socket using the
// line-oriented JSON framing of QMP. Communication runs entirely on
// the calling thread. Every command and every poll drains the socket with a
// deadline, so a hung QEMU can never block the caller forever.
//
// Core model
// ----------
//   * A `Client` carries the per-connection state: the socket fd, the read
//     buffer, the buffered-event queue, and an allocator that owns all
//     client-managed memory.
//   * `send` clears the event buffer, writes a command, then reads until the
//     command's JSON reply arrives or the deadline is hit. Events seen while
//     waiting are buffered.
//   * `poll` reads whatever is currently available (bounded by a timeout),
//     appending any events to the queue, and reports whether it drained any.
//     A poll timeout is NOT an error: it just returns control to the caller.
//   * The buffered events are read straight from the client: `c.events[:]`
//     is the queue, oldest first. There is no copy and no separate accessor.
//   * `consume` discards the n oldest buffered events — the ones the caller
//     has finished treating.
//
// Memory model
// ------------
// The buffered events (`c.events[:]`) and the strings they carry are owned by
// the client and freed when they are consumed (or the buffer is cleared by
// `send`/`close`). Do not retain them across those calls, or clone what you
// need first. The same holds for the strings in a `Reply`: they are freed on
// the next `send`/`close`.

package qmp

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sys/posix"
import "core:time"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Error codes that can be returned by the QMP client. `.None` means success.
Error :: enum {
	None,
	Connect_Failed, ///< Could not establish / negotiate the connection.
	Not_Connected, ///< Operation attempted on a closed / unconnected client.
	Timeout, ///< A command deadline elapsed (VM unresponsive). NOT used for poll.
	Protocol_Error, ///< QEMU sent something that was not valid QMP JSON.
	Connection_Lost, ///< The peer closed or reset the connection mid-operation.
	Write_Failed, ///< A socket write failed.
}

/// Structured details about a command rejected by QEMU (an `{"error":...}` reply).
QMP_Error :: struct {
	class: string,
	desc:  string,
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/// A single asynchronous event delivered by QEMU (`{"event":...}`).
Event :: struct {
	name: string, ///< The event name (e.g. "STOP", "RESET", "SHUTDOWN").
	raw:  string, ///< The raw JSON line, for callers that want the full payload.
}

/// The result of a `send` command. Either `ok` and `return_json` are set, or
/// `ok == false` and `err` describes the QEMU-level rejection.
Reply :: struct {
	ok:          bool, ///< True on success (return_json set), false on QEMU error (err set).
	complete:    bool, ///< True once ANY reply (return or error) has been received.
	return_json: string, ///< Raw JSON of the `"return"` payload (set when ok).
	err:         QMP_Error, ///< QEMU error class/desc (set when !ok).
}

/// Optional logging sink. Implement `log` to trace protocol I/O.
Logger :: proc(msg: string)

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Fixed capacity of the circular read buffer. QMP lines are small; partial
/// lines larger than this are treated as a protocol error.
READ_BUF_CAP :: 256 * 1024

/// Handle to one QMP connection. Single-threaded: do not share across threads.
Client :: struct {
	conn:       posix.FD, ///< Underlying socket fd (invalid when !connected).
	transport:  Transport, ///< How the fd is obtained / released.
	connected:  bool,
	/// Circular read buffer: bytes in [rstart, rstart+rlen) are unconsumed.
	rbuf:       []u8,
	rstart:     int,
	rlen:       int,
	events:     [dynamic]Event, ///< Buffered events (send + poll).
	allocator:  runtime.Allocator, ///< Owns all client-managed memory.
	logger:     Logger, ///< Optional; nil = silent.
	/// Storage backing the most recent reply; freed on the next send/close so a
	/// `Reply` never dangles while the caller inspects it.
	last_reply: Reply,
}

// ---------------------------------------------------------------------------
// Scratch arena
// ---------------------------------------------------------------------------

/// Fixed size of the per-call scratch arena. Lines parse into this (a 64 KiB
/// read buffer plus JSON parse garbage per line); the arena is swapped in as
/// the thread's temp allocator and discarded wholesale at call end.
SCRATCH_CAP :: 512 * 1024

/// Swap the thread's temp allocator for a private per-call arena. All scratch
/// work inside connect/send/poll (JSON parses, line framing) goes through
/// `context.temp_allocator`; routing it to a private arena means a public call
/// neither leaks scratch into the caller's temp arena NOR frees that arena —
/// a `free_all(context.temp_allocator)` here would destroy OTHER live temp
/// allocations the caller may still hold (this bit the fake test server: a
/// send() wiped the arena its state struct lived in). Swaps nest safely.
@(private = "file")
_scratch_swap :: proc(c: ^Client, arena: ^mem.Arena) -> (backing: []u8, prev: runtime.Allocator) {
	backing = make([]u8, SCRATCH_CAP, c.allocator)
	if backing == nil {
		return nil, {} // out of client memory: fall back to the ambient temp arena
	}
	mem.arena_init(arena, backing)
	prev = context.temp_allocator
	context.temp_allocator = mem.arena_allocator(arena)
	return
}

@(private = "file")
_scratch_restore :: proc(c: ^Client, backing: []u8, prev: runtime.Allocator) {
	if backing == nil {
		return
	}
	context.temp_allocator = prev
	delete(backing, c.allocator)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

_log :: proc(c: ^Client, msg: string) {
	if c.logger != nil {
		c.logger(msg)
	}
}

/// Best-effort logging; never fails the caller.
_logf :: proc(c: ^Client, format: string, args: ..any) {
	if c.logger == nil {
		return
	}
	msg := fmt.tprintf(format, ..args)
	c.logger(msg)
}

/// Free the raw storage of every buffered event and reset the queue.
_clear_events :: proc(c: ^Client) {
	for ev in c.events {
		delete(ev.name, c.allocator)
		delete(ev.raw, c.allocator)
	}
	clear(&c.events)
}

/// Free the storage backing the previous reply.
_clear_last_reply :: proc(c: ^Client) {
	delete(c.last_reply.return_json, c.allocator)
	delete(c.last_reply.err.class, c.allocator)
	delete(c.last_reply.err.desc, c.allocator)
	c.last_reply = {}
}

/// Append an event to the queue, cloning its strings into client memory.
_push_event :: proc(c: ^Client, name, raw: string) {
	n, _ := strings.clone(name, c.allocator)
	r, _ := strings.clone(raw, c.allocator)
	append(&c.events, Event{name = n, raw = r})
}

/// Block until the fd is readable, `timeout_ms` elapses, or an error occurs.
/// Returns .None when readable, .Timeout when the deadline elapsed, or another
/// error if the connection broke / poll itself failed.
_wait_readable :: proc(c: ^Client, timeout_ms: i32) -> Error {
	pfd := posix.pollfd {
		fd     = c.conn,
		events = {.IN},
	}
	ms := i32(timeout_ms < 0 ? 0 : timeout_ms)
	n := posix.poll(&pfd, 1, ms)
	if n < 0 {
		return .Connection_Lost
	}
	if n == 0 {
		return .Timeout
	}
	if .HUP in pfd.revents || .ERR in pfd.revents || .NVAL in pfd.revents {
		// Readable-with-error still may carry data; but a hard HUP/ERR on a
		// stream socket with nothing else means the peer went away.
		if .IN not_in pfd.revents {
			return .Connection_Lost
		}
	}
	return .None
}

/// Write the whole buffer, retrying on EAGAIN until the deadline. Used for
/// command writes (QMP command lines are small, so this rarely loops).
_write_all :: proc(c: ^Client, b: []u8, deadline: time.Time) -> Error {
	off := 0
	for off < len(b) {
		count := len(b) - off
		n := posix.write(c.conn, raw_data(b[off:]), uint(count))
		if n > 0 {
			off += int(n)
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) {
			remaining_ms := _ms_until(deadline)
			if remaining_ms <= 0 {
				return .Timeout
			}
			pfd := posix.pollfd {
				fd     = c.conn,
				events = {.OUT},
			}
			if posix.poll(&pfd, 1, remaining_ms) < 0 {
				return .Write_Failed
			}
			continue
		}
		return .Write_Failed
	}
	return .None
}

/// Drain available bytes, frame complete lines, and dispatch them: events are
/// buffered, replies fill `reply`. Returns when the socket is empty, a reply
/// arrived, the deadline passed, or an error occurred.
_drain :: proc(c: ^Client, deadline: time.Time, reply: ^Reply, want_reply: bool) -> Error {
	buf := make([]u8, 64 * 1024, context.temp_allocator)
	defer delete(buf, context.temp_allocator)

	for {
		// Wait for readability (poll with 0 timeout = pure non-blocking drain).
		if werr := _wait_readable(c, _ms_until(deadline)); werr != .None {
			return werr
		}

		// Non-blocking drain: read until EAGAIN.
		for {
			n := posix.read(c.conn, raw_data(buf), uint(len(buf)))
			if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) {
				break
			}
			if n <= 0 { 	// error (n<0, non-EAGAIN), or orderly peer shutdown (n==0)
				c.connected = false
				return .Connection_Lost
			}
			if berr := _buffer(c, buf[:int(n)]); berr != .None {
				return berr
			}

			// Frame and dispatch every complete line now buffered.
			for {
				line, ok := _next_line(c)
				if !ok {
					break
				}
				if derr := _dispatch_line(c, line, reply); derr != .None {
					return derr
				}
				if want_reply && reply.complete {
					return .None
				}
			}
		}

		if want_reply && reply.complete {
			return .None
		}
		if !want_reply && _expired(deadline) {
			return .Timeout
		}
	}
}

/// Read raw bytes until the QMP greeting line arrives, then consume it. The
/// greeting is neither a reply nor an event, so it is handled here directly
/// rather than going through `_drain`'s dispatch.
_read_greeting :: proc(c: ^Client, deadline: time.Time) -> Error {
	buf := make([]u8, 64 * 1024, context.temp_allocator)
	defer delete(buf, context.temp_allocator)
	for {
		if line, ok := _next_line(c); ok {
			_logf(c, "qmp: greeting: %s", line)
			return .None
		}
		if werr := _wait_readable(c, _ms_until(deadline)); werr != .None {
			return werr
		}
		if ferr := _fill(c, buf); ferr != .None {
			return ferr
		}
	}
}

/// Copy bytes into the circular read buffer, compacting first if needed.
_buffer :: proc(c: ^Client, data: []u8) -> Error {
	if c.rlen + len(data) > len(c.rbuf) {
		// Compact: move the unconsumed window to the front.
		for i in 0 ..< c.rlen {
			c.rbuf[i] = c.rbuf[c.rstart + i]
		}
		c.rstart = 0
	}
	if c.rlen + len(data) > len(c.rbuf) {
		return .Protocol_Error // single line larger than the whole buffer
	}
	for b, i in data {
		c.rbuf[c.rstart + c.rlen + i] = b
	}
	c.rlen += len(data)
	return .None
}

/// Read into a scratch buffer then copy into the ring buffer (single-line use
/// in `_read_greeting`).
_fill :: proc(c: ^Client, buf: []u8) -> Error {
	n := posix.read(c.conn, raw_data(buf), uint(len(buf)))
	if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EWOULDBLOCK) {
		return .None
	}
	if n <= 0 {
		c.connected = false
		return .Connection_Lost
	}
	return _buffer(c, buf[:int(n)])
}

/// Pop the next complete '\n'-terminated line from the read buffer. The
/// returned string is a clone owned by the temp allocator; `ok` is false when
/// no full line is buffered yet. Consumes the bytes from the ring buffer.
_next_line :: proc(c: ^Client) -> (line: string, ok: bool) {
	idx := -1
	for i in 0 ..< c.rlen {
		if c.rbuf[c.rstart + i] == '\n' {
			idx = i
			break
		}
	}
	if idx < 0 {
		return "", false
	}
	raw := string(c.rbuf[c.rstart:c.rstart + idx])
	line = strings.trim_space(raw)
	// Consume the line plus its newline.
	c.rstart += idx + 1
	c.rlen -= idx + 1
	if c.rlen == 0 {
		c.rstart = 0 // reset for the next burst
	}
	return line, len(line) > 0
}

/// Inspect one JSON line: buffer events, fill `reply` on command replies.
_dispatch_line :: proc(c: ^Client, line: string, reply: ^Reply) -> Error {
	value, perr := json.parse_string(line, json.Specification.JSON, false, context.temp_allocator)
	if perr != nil {
		_logf(c, "qmp: ignoring unparseable line: %s", line)
		return .None
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return .None
	}

	// Asynchronous event?
	if ev, has := obj["event"]; has {
		if name, is_str := ev.(json.String); is_str {
			_logf(c, "qmp: EVENT %s", name)
			_push_event(c, name, line)
		}
		return .None
	}

	// Command reply: success payload.
	if ret, has := obj["return"]; has {
		js, _ := json.marshal(ret, {}, context.temp_allocator)
		reply.ok = true
		reply.complete = true
		reply.return_json = strings.clone(string(js), c.allocator)
		return .None
	}

	// Command reply: error payload.
	if e, has := obj["error"]; has {
		if eo, is_obj := e.(json.Object); is_obj {
			if cls, ok := eo["class"].(json.String); ok {
				reply.err.class = strings.clone(cls, c.allocator)
			}
			if dsc, ok := eo["desc"].(json.String); ok {
				reply.err.desc = strings.clone(dsc, c.allocator)
			}
		}
		reply.complete = true
		_logf(c, "qmp: command rejected: %s: %s", reply.err.class, reply.err.desc)
		return .None
	}

	_logf(c, "qmp: ignoring unrecognized message: %s", line)
	return .None
}

// ---------------------------------------------------------------------------
// Deadline helpers
// ---------------------------------------------------------------------------

_deadline :: proc(timeout: time.Duration) -> time.Time {
	if timeout <= 0 {
		// Effectively "no wait": immediate.
		return time.now()
	}
	return time.time_add(time.now(), timeout)
}

_expired :: proc(deadline: time.Time) -> bool {
	return time.since(deadline) > 0
}

_ms_until :: proc(deadline: time.Time) -> i32 {
	d := time.diff(time.now(), deadline)
	if d <= 0 {
		return 0
	}
	ms := time.duration_milliseconds(d)
	return i32(ms) if ms < f64(max(i32)) else max(i32)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Connect over a `transport`, perform the greeting + `qmp_capabilities`
/// handshake, and return a ready client. `timeout` bounds the whole
/// connect+handshake. `allocator` owns all client memory.
connect_transport :: proc(
	t: Transport,
	timeout: time.Duration = 5 * time.Second,
	allocator: runtime.Allocator = context.allocator,
	logger: Logger = nil,
) -> (
	client: Client,
	err: Error,
) {

	c: Client
	c.allocator = allocator
	c.logger = logger
	c.transport = t
	c.rbuf = make([]u8, READ_BUF_CAP, allocator)
	c.events = make([dynamic]Event, 0, 8, allocator)

	deadline := _deadline(timeout)

	fd, cerr := t.connect(t.data, deadline)
	if cerr != .None {
		_free_transport(&c)
		delete(c.rbuf)
		delete(c.events)
		err = cerr
		return
	}
	c.conn = fd
	c.connected = true

	// per-call scratch for greeting + handshake (see _scratch_swap);
	// restored before returning
	arena: mem.Arena
	backing, prev := _scratch_swap(&c, &arena)
	defer _scratch_restore(&c, backing, prev)

	// 1. Read the QMP greeting ({"QMP": ...}). It is neither a reply nor an
	// event, so we pop its line directly rather than dispatching it.
	if gerr := _read_greeting(&c, deadline); gerr != .None {
		close(&c)
		err = gerr
		return
	}

	// 2. Negotiate capabilities.
	if r, serr := send(&c, `{"execute":"qmp_capabilities"}`, _remaining(deadline)); serr != .None {
		close(&c)
		err = serr
		return
	} else if !r.ok {
		close(&c)
		err = .Protocol_Error
		return
	}

	_log(&c, "qmp: connected and negotiated")
	client = c
	return c, .None
}

/// Connect to a QEMU QMP Unix socket at `socket_path`. Convenience wrapper
/// around `connect_transport` for the common Unix-socket case.
connect :: proc(
	socket_path: string,
	timeout: time.Duration = 5 * time.Second,
	allocator: runtime.Allocator = context.allocator,
	logger: Logger = nil,
) -> (
	Client,
	Error,
) {
	t: Transport
	if !unix_transport(&t, socket_path) {
		return {}, .Connect_Failed
	}
	return connect_transport(t, timeout, allocator, logger)
}

/// Connect to a QEMU QMP TCP endpoint ("host:port"). Convenience wrapper
/// around `connect_transport` for the TCP case.
connect_tcp :: proc(
	endpoint: string,
	timeout: time.Duration = 5 * time.Second,
	allocator: runtime.Allocator = context.allocator,
	logger: Logger = nil,
) -> (
	Client,
	Error,
) {
	t: Transport
	if !tcp_transport(&t, endpoint) {
		return {}, .Connect_Failed
	}
	return connect_transport(t, timeout, allocator, logger)
}

/// Remaining time until a deadline as a Duration (>= 0).
_remaining :: proc(deadline: time.Time) -> time.Duration {
	d := time.diff(time.now(), deadline)
	return d > 0 ? d : 0
}

/// Close the connection and free all client memory.
close :: proc(c: ^Client) {
	_close_fd(c)
	_clear_events(c)
	_clear_last_reply(c)
	// `c.rbuf` is a `[]u8`; `delete` on a slice defaults to
	// `context.allocator`, which is *not* the allocator the slice was
	// allocated with at connect time. Pass `c.allocator` explicitly.
	// (`c.events` is a `[dynamic]Event`, which carries its allocator in
	// the array header — `delete` reads it from there, so the bare
	// `delete(c.events)` is already correct.)
	delete(c.rbuf, c.allocator)
	delete(c.events)
}

_close_fd :: proc(c: ^Client) {
	if c.connected {
		c.transport.close(c.transport.data, c.conn)
		c.transport = {}
	}
	c.connected = false
}

// Free a transport's state without touching the fd (used when connect fails).
_free_transport :: proc(c: ^Client) {
	if c.transport.close != nil {
		c.transport.close(c.transport.data, 0)
	}
	c.transport = {}
}

/// Is the client connected?
connected :: proc(c: ^Client) -> bool {
	return c.connected
}

/// Send a QMP command (a JSON command line such as `{"execute":"query-status"}`)
/// and synchronously await its reply. Clears the event buffer first; events that
/// arrive while waiting are buffered and can be retrieved with `events`.
///
/// A `timeout` elapsed means the VM is unresponsive -> `.Timeout` (a big error).
send :: proc(
	c: ^Client,
	command: string,
	timeout: time.Duration = 5 * time.Second,
) -> (
	reply: Reply,
	err: Error,
) {
	if !c.connected {
		return {}, .Not_Connected
	}

	_clear_events(c)
	_clear_last_reply(c)
	// per-call scratch (see _scratch_swap); restored on return
	arena: mem.Arena
	backing, prev := _scratch_swap(c, &arena)
	defer _scratch_restore(c, backing, prev)

	deadline := _deadline(timeout)

	// Write the command line.
	{
		n := len(command)
		buf := make([]u8, n + 1, context.temp_allocator)
		copy(buf, command)
		buf[n] = '\n'
		if werr := _write_all(c, buf, deadline); werr != .None {
			return {}, werr
		}
	}
	_logf(c, "qmp: CMD -> %s", command)

	// Read until the reply arrives or the deadline passes.
	derr := _drain(c, deadline, &reply, true)
	if derr == .Timeout {
		_log(c, "qmp: command timed out (VM unresponsive)")
		return {}, .Timeout
	}
	if derr != .None {
		return {}, derr
	}
	// Keep the backing storage alive for the caller; freed on next send/close.
	c.last_reply = reply
	return reply, .None
}

/// Read any QMP messages currently available, buffering events. Keeps going
/// until there is nothing more to read OR `timeout` elapses; a poll timeout is
/// NOT an error: it returns `.None`. Returns whether any events were drained
/// during this call — they are appended to the buffer, so read them from
/// `c.events[:]` and discard them with `consume` once treated.
poll :: proc(c: ^Client, timeout: time.Duration = 0) -> (drained: bool, err: Error) {
	if !c.connected {
		return false, .Not_Connected
	}
	start := len(c.events)
	// per-call scratch (see _scratch_swap); restored on return
	arena: mem.Arena
	backing, prev := _scratch_swap(c, &arena)
	defer _scratch_restore(c, backing, prev)
	deadline := _deadline(timeout)
	discard := Reply{}
	derr := _drain(c, deadline, &discard, false)
	err = .None if derr == .Timeout else derr
	drained = len(c.events) > start
	return
}

/// Discard the `n` oldest buffered events, freed with the client's allocator.
/// `n` larger than the buffered count consumes everything (clamped); the
/// n-vs-count check is the caller's job when over-consumption is an error
/// (the Lua binding raises on it).
consume :: proc(c: ^Client, n: int) {
	n := min(n, len(c.events))
	if n <= 0 {
		return
	}
	for i in 0 ..< n {
		delete(c.events[i].name, c.allocator)
		delete(c.events[i].raw, c.allocator)
	}
	copy(c.events[:], c.events[n:])
	resize(&c.events, len(c.events) - n)
}
