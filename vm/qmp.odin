// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

import lua "vendor:lua/5.4"

import "../qmp"

// QMP client primitive (design/qmp.md), an
// object-style Lua API over the ./qmp package, one persistent connection
// per client object:
//
//   local qmp = makac.qmp_open("/run/vm/qmp.socket")          -- unix socket
//   local qmp = makac.qmp_open({ tcp = "127.0.0.1:4444" })    -- tcp endpoint
//   local qmp = makac.qmp_open({ socket = path, timeout_s = 5 })
//
//   qmp:send(commands, { timeout_s = }?) -> results
//       commands: array of { execute = <string>, arguments = <table>? },
//       sent in array order. results: array (same length, same order) of
//         { ["return"] = <decoded payload> }               -- on success, or
//         { error = { class = <string>, desc = <string> } } -- on QMP error
//       A QMP error reply is DATA (a result entry); transport failures
//       (connect lost, timeout, ...) raise. Send clears the event buffer
//       first: a new command retires prior events (qmp.md).
//   qmp:poll({ timeout_s = }?) -> bool
//       Drains the socket (timeout is not an error; default 0: no wait),
//       appends any events to the buffer, and returns whether any arrived.
//   qmp:events(n?) -> events
//       Returns the first n buffered events (all of them when n is omitted) as
//         { name = <string>, data = <table>?, timestamp = <table>? }
//       They STAY buffered; discard them once treated:
//   qmp:consume(n)   -- drops the n oldest buffered events; raises when n
//                       exceeds the buffered count
//   qmp:close()      -- idempotent; __gc is the backstop for leaked clients
//
// Lua receives and produces plain tables throughout; the JSON wire format is
// never part of the surface.

QMP_MT :: "makac.qmp"

// The object carried inside the Lua userdata. `client` is inline (the
// userdata owns it); `opened` guards against double-close — qmp.close frees
// client memory, so it must run at most once.
QMP_Object :: struct {
	client: qmp.Client,
	label:  string, // endpoint string (owned); for errors and __tostring
	opened: bool,
}

register_qmp_primitives :: proc(v: ^VM) {
	L := v.state
	if lua.L_newmetatable(L, QMP_MT) != 0 {
		lua.pushcclosure(L, _qmp_index, 0)
		lua.setfield(L, -2, "__index")
		lua.pushcclosure(L, _qmp_gc, 0)
		lua.setfield(L, -2, "__gc")
		lua.pushcclosure(L, _qmp_tostring, 0)
		lua.setfield(L, -2, "__tostring")
	}
	lua.pop(L, 1)
	register(v, "qmp_open", _makac_qmp_open)
}

@(private = "file")
_qmp_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checkudata(L, 1, QMP_MT)
	if lua.Type(lua.type(L, 2)) != .STRING {
		lua.pushnil(L)
		return 1
	}
	switch runtime.cstring_to_string(lua.tostring(L, 2)) {
	case "send":    lua.pushcclosure(L, _qmp_send, 0)
	case "poll":    lua.pushcclosure(L, _qmp_poll, 0)
	case "events":  lua.pushcclosure(L, _qmp_events, 0)
	case "consume": lua.pushcclosure(L, _qmp_consume, 0)
	case "close":   lua.pushcclosure(L, _qmp_close, 0)
	case:           lua.pushnil(L)
	}
	return 1
}

// __gc: the leak backstop — closes the connection of any client that escaped
// an explicit close(). Never raises; safe work only (frees + fd close).
@(private = "file")
_qmp_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^QMP_Object)(lua.L_checkudata(L, 1, QMP_MT))
	if self.opened {
		qmp.close(&self.client)
		self.opened = false
	}
	if self.label != "" {delete(self.label, context.allocator)}
	return 0
}

@(private = "file")
_qmp_tostring :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^QMP_Object)(lua.L_checkudata(L, 1, QMP_MT))
	label := strings.clone_to_cstring(self.label, context.temp_allocator)
	if self.opened {
		lua.pushfstring(L, "makac.qmp: %s", label)
	} else {
		lua.pushfstring(L, "makac.qmp: %s (closed)", label)
	}
	return 1
}

@(private = "file")
_qmp_err_str :: proc(e: qmp.Error) -> string {
	switch e {
	case .None:            return "no error"
	case .Connect_Failed:  return "connect/handshake failed"
	case .Not_Connected:   return "not connected"
	case .Timeout:         return "timed out (VM unresponsive)"
	case .Protocol_Error:  return "protocol error"
	case .Connection_Lost: return "connection lost"
	case .Write_Failed:    return "write failed"
	}
	return "unknown error"
}

// Type-checked self + open-client guard shared by the methods.
@(private = "file")
_check_qmp :: proc "c" (L: ^lua.State, op: cstring) -> ^QMP_Object {
	self := (^QMP_Object)(lua.L_checkudata(L, 1, QMP_MT))
	if !self.opened {
		lua.L_error(L, "makac.qmp: client is closed — %s is no longer allowed", op)
		return nil
	}
	return self
}

// Read an optional `timeout_s` (seconds, number) field from the opts table at
// `idx`, defaulting to `def`.
@(private = "file")
_timeout_opt :: proc "c" (L: ^lua.State, idx: c.int, def: time.Duration) -> time.Duration {
	if lua.isnoneornil(L, idx) {return def}
	lua.L_checktype(L, idx, c.int(lua.Type.TABLE))
	t := lua.getfield(L, idx, "timeout_s")
	defer lua.pop(L, 1)
	if t == c.int(lua.Type.NIL) {return def}
	if t != c.int(lua.Type.NUMBER) {
		lua.L_error(L, "makac.qmp: opts.timeout_s must be a number (seconds)")
		return def
	}
	secs := f64(lua.tonumber(L, -1))
	if secs < 0 {
		lua.L_error(L, "makac.qmp: opts.timeout_s must not be negative")
		return def
	}
	return time.Duration(secs * 1e9)
}

// makac.qmp_open(spec) -> client userdata
// spec: a unix socket path (plain string), or a table with exactly one of
// `socket` (unix path) / `tcp` ("host:port"), and an optional `timeout_s`
// bounding connect+handshake (default 5).
@(private = "file")
_makac_qmp_open :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	socket_path := ""
	tcp_endpoint := ""
	timeout: time.Duration = 5 * time.Second

	if lua.Type(lua.type(L, 1)) == .STRING {
		l: c.size_t
		s := lua.tolstring(L, 1, &l)
		socket_path = _cstr(s, l)
	} else if !lua.isnoneornil(L, 1) {
		lua.L_checktype(L, 1, c.int(lua.Type.TABLE))
		if s, ok := _opt_string_field(L, 1, "socket"); ok {socket_path = s}
		if s, ok := _opt_string_field(L, 1, "tcp"); ok {tcp_endpoint = s}
		if socket_path != "" && tcp_endpoint != "" {
			return c.int(lua.L_error(L, "makac.qmp_open: give either spec.socket or spec.tcp, not both"))
		}
		if socket_path == "" && tcp_endpoint == "" {
			return c.int(lua.L_error(L, "makac.qmp_open: spec must set socket (unix path) or tcp (\"host:port\")"))
		}
		timeout = _timeout_opt(L, 1, timeout)
	}

	client: qmp.Client
	cerr: qmp.Error
	label: string
	if tcp_endpoint != "" {
		client, cerr = qmp.connect_tcp(tcp_endpoint, timeout, context.allocator)
		label = tcp_endpoint
	} else if socket_path != "" {
		client, cerr = qmp.connect(socket_path, timeout, context.allocator)
		label = socket_path
	} else {
		return c.int(lua.L_error(L, "makac.qmp_open: a unix socket path (string) or a spec table is required"))
	}
	if cerr != .None {
		return c.int(
			lua.L_error(
				L,
				"makac.qmp_open: %s: %s",
				strings.clone_to_cstring(label, context.temp_allocator),
				strings.clone_to_cstring(_qmp_err_str(cerr), context.temp_allocator),
			),
		)
	}

	ud := (^QMP_Object)(lua.newuserdata(L, c.size_t(size_of(QMP_Object))))
	ud^ = QMP_Object {
		client = client,
		label  = strings.clone(label, context.allocator),
		opened = true,
	}
	lua.L_setmetatable(L, QMP_MT)
	return 1
}

// qmp:send(commands, opts?) -> results array
@(private = "file")
_qmp_send :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_qmp(L, "send")
	if self == nil {return 0}
	lua.L_checktype(L, 2, c.int(lua.Type.TABLE))
	timeout := _timeout_opt(L, 3, 5 * time.Second)

	n := int(lua.rawlen(L, 2))
	if n == 0 {
		return c.int(lua.L_error(L, "makac.qmp: send: commands must contain at least one command"))
	}

	lua.createtable(L, c.int(n), 0) // results; stays on top until returned
	for i in 1 ..= n {
		lua.rawgeti(L, 2, lua.Integer(i)) // ... results cmd
		cmd_idx := lua.gettop(L)
		if lua.Type(lua.type(L, cmd_idx)) != .TABLE {
			return c.int(lua.L_error(L, "makac.qmp: send: commands[%d] must be a table", i))
		}
		path := fmt.tprintf("commands[%d]", i)

		exe: string
		if t := lua.getfield(L, cmd_idx, "execute"); t == c.int(lua.Type.STRING) {
			l: c.size_t
			s := lua.tolstring(L, -1, &l)
			// clone: the Lua string may be collected once its table is popped
			exe = strings.clone(_cstr(s, l), context.temp_allocator)
		} else {
			lua.pop(L, 1)
			return c.int(lua.L_error(L, "makac.qmp: send: %s.execute must be a string", cstring(raw_data(path))))
		}
		lua.pop(L, 1) // execute

		// marshal the command line: {"execute":..., "arguments":...?}
		cmd_obj := make(json.Object, allocator = context.temp_allocator)
		cmd_obj["execute"] = json.String(exe)
		if t := lua.getfield(L, cmd_idx, "arguments"); t == c.int(lua.Type.TABLE) {
			cmd_obj["arguments"] = _lua_to_json(L, -1, fmt.tprintf("%s.arguments", path), "makac.qmp", 0)
		} else if t != c.int(lua.Type.NIL) {
			lua.pop(L, 1)
			return c.int(lua.L_error(L, "makac.qmp: send: %s.arguments must be a table", cstring(raw_data(path))))
		}
		lua.pop(L, 1) // arguments / nil
		lua.pop(L, 1) // the command table; ... results

		line, merr := json.marshal(json.Value(cmd_obj), {}, context.temp_allocator)
		if merr != nil {
			return c.int(lua.L_error(L, "makac.qmp: send: %s: failed to encode as JSON", cstring(raw_data(path))))
		}

		reply, serr := qmp.send(&self.client, string(line), timeout)
		if serr != .None {
			return c.int(
				lua.L_error(
					L,
					"makac.qmp: send: %s (%s): %s",
					cstring(raw_data(path)),
					strings.clone_to_cstring(exe, context.temp_allocator),
					strings.clone_to_cstring(_qmp_err_str(serr), context.temp_allocator),
				),
			)
		}

		// build the result entry
		lua.createtable(L, 0, 1) // ... results entry
		if reply.ok {
			// already parsed by the qmp package; push it straight through
			_push_json(L, reply.return_json, 0)
			lua.setfield(L, -2, "return")
		} else {
			lua.createtable(L, 0, 2)
			_push_lstring(L, reply.err.class)
			lua.setfield(L, -2, "class")
			_push_lstring(L, reply.err.desc)
			lua.setfield(L, -2, "desc")
			lua.setfield(L, -2, "error")
		}
		lua.rawseti(L, -2, lua.Integer(i)) // results[i] = entry
	}
	return 1
}

// qmp:poll(opts?) -> bool (true when events were drained into the buffer)
@(private = "file")
_qmp_poll :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_qmp(L, "poll")
	if self == nil {return 0}
	timeout := _timeout_opt(L, 2, 0)

	drained, perr := qmp.poll(&self.client, timeout)
	if perr != .None {
		return c.int(
			lua.L_error(
				L,
				"makac.qmp: poll: %s: %s",
				strings.clone_to_cstring(self.label, context.temp_allocator),
				strings.clone_to_cstring(_qmp_err_str(perr), context.temp_allocator),
			),
		)
	}
	lua.pushboolean(L, b32(drained))
	return 1
}

// qmp:events(n?) -> events array (the first n buffered events; all when n is
// omitted). The events stay buffered — discard them with consume once treated.
@(private = "file")
_qmp_events :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_qmp(L, "events")
	if self == nil {return 0}

	buffered := len(self.client.events)
	n := buffered
	if !lua.isnoneornil(L, 2) {
		n = int(lua.L_checkinteger(L, 2))
		if n < 0 {
			return c.int(lua.L_error(L, "makac.qmp: events: n must not be negative"))
		}
		if n > buffered {
			return c.int(
				lua.L_error(
					L,
					"makac.qmp: events: cannot read %d events, only %d buffered",
					n,
					buffered,
				),
			)
		}
	}

	lua.createtable(L, c.int(n), 0)
	for i in 0 ..< n {
		ev := self.client.events[i]
		lua.createtable(L, 0, 3) // ... events entry
		_push_lstring(L, ev.name)
		lua.setfield(L, -2, "name")
		// already parsed by the qmp package; walk it straight through
		if obj, is_obj := ev.payload.(json.Object); is_obj {
			if data, has := obj["data"]; has {
				_push_json(L, data, 0)
				lua.setfield(L, -2, "data")
			}
			if ts, has := obj["timestamp"]; has {
				_push_json(L, ts, 0)
				lua.setfield(L, -2, "timestamp")
			}
		}
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// qmp:consume(n) — drop the n oldest buffered events.
@(private = "file")
_qmp_consume :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_qmp(L, "consume")
	if self == nil {return 0}
	n := lua.L_checkinteger(L, 2)
	if n < 0 {
		return c.int(lua.L_error(L, "makac.qmp: consume: n must not be negative"))
	}
	buffered := len(self.client.events)
	if int(n) > buffered {
		return c.int(
			lua.L_error(
				L,
				"makac.qmp: consume: cannot consume %d events, only %d buffered",
				int(n),
				buffered,
			),
		)
	}
	qmp.consume(&self.client, int(n))
	return 0
}

// qmp:close() — idempotent.
@(private = "file")
_qmp_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^QMP_Object)(lua.L_checkudata(L, 1, QMP_MT))
	if self.opened {
		qmp.close(&self.client)
		self.opened = false
	}
	return 0
}
