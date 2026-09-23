// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

import lua "vendor:lua/5.4"

import "../ssh"

// Remote (SSH) session primitive (design/target.md), an object-style Lua API:
//
//   local sess = makac._ssh_open(name, { host, user, port?, options? })
//   sess:run(command, opts?) -> { code, stdout, stderr }
//   sess:put(local_path, remote_path)   -- raises on failure
//   sess:get(remote_path, local_path)   -- raises on failure
//   sess:close()                        -- idempotent
//   sess.name, sess.port                -- introspection
//
// A session is full userdata holding an SSH_Session; the "makac.ssh"
// metatable's __index dispatches the methods above. Creating a session writes
// an OpenSSH config under <data_dir>/targets/<name>/ssh.conf (via
// ssh.generate_config) with ControlMaster/ControlPath/ControlPersist set, so
// the first invocation establishes an authenticated master connection and
// every later run/put/get multiplexes through it ("reaching a remote target
// authenticates once"). No connection happens at construction — only config
// generation.
//
// Lifecycle: close() tears the control master down (best-effort `ssh -O
// exit`). __gc only frees memory — it never spawns processes; a session
// leaked past close() is backstopped by ControlPersist expiry. The prelude
// wraps sessions into remote targets (makac.new_ssh_target), and run-end
// teardown (makac.close_all_targets) is the deterministic close path.
//
// Non-zero exit of a `run` command is DATA, not an error (design/target.md):
// :run returns the exit code; only failure to execute at all (no ssh binary,
// unreachable host) raises. put/get failures are errors.

SSH_MT :: "makac.ssh"

SSH_Session :: struct {
	name:        string, // owned (context.allocator), freed by __gc
	config_path: string, // owned (context.allocator), freed by __gc
	port:        int,
	closed:      bool,
}

register_ssh_primitives :: proc(v: ^VM) {
	L := v.state
	if lua.L_newmetatable(L, SSH_MT) != 0 {
		lua.pushcclosure(L, _ssh_index, 0)
		lua.setfield(L, -2, "__index")
		lua.pushcclosure(L, _ssh_gc, 0)
		lua.setfield(L, -2, "__gc")
		lua.pushcclosure(L, _ssh_tostring, 0)
		lua.setfield(L, -2, "__tostring")
	}
	lua.pop(L, 1)
	register(v, "_ssh_open", _makac_ssh_open)
}

// __index: method dispatch plus introspection fields (name, port).
@(private = "file")
_ssh_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^SSH_Session)(lua.L_checkudata(L, 1, SSH_MT))
	if lua.Type(lua.type(L, 2)) != .STRING {
		lua.pushnil(L)
		return 1
	}
	switch runtime.cstring_to_string(lua.tostring(L, 2)) {
	case "run":   lua.pushcclosure(L, _sess_run, 0)
	case "put":   lua.pushcclosure(L, _sess_put, 0)
	case "get":   lua.pushcclosure(L, _sess_get, 0)
	case "close": lua.pushcclosure(L, _sess_close, 0)
	case "name":  _push_lstring(L, self.name)
	case "port":  lua.pushinteger(L, lua.Integer(self.port))
	case:         lua.pushnil(L)
	}
	return 1
}

// __gc: free Odin-side memory. Never spawns processes (that would be close()'s
// `ssh -O exit`) and never raises — runs during GC / lua_close.
@(private = "file")
_ssh_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^SSH_Session)(lua.L_checkudata(L, 1, SSH_MT))
	if self.name != "" {delete(self.name, context.allocator)}
	if self.config_path != "" {delete(self.config_path, context.allocator)}
	self^ = {}
	return 0
}

@(private = "file")
_ssh_tostring :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^SSH_Session)(lua.L_checkudata(L, 1, SSH_MT))
	name := strings.clone_to_cstring(self.name, context.temp_allocator)
	if self.closed {
		lua.pushfstring(L, "makac.ssh: %s (closed)", name)
	} else {
		lua.pushfstring(L, "makac.ssh: %s", name)
	}
	return 1
}

// Run `program args...` capturing stdout/stderr separately (see
// exec_capture). The binary is resolved via ssh.resolve_command first so a
// missing ssh/scp surfaces as a clear spawn error instead of a fork
// fallback mishap.
@(private = "file")
_ssh_capture :: proc(
	program: string,
	args: []string,
	stdin_data: Maybe(string) = nil,
) -> (
	res: Exec_Result,
	err: os.Error,
) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, program)
	for a in args {append(&argv, a)}
	// exec_capture reports a spawn failure (e.g. ssh not on PATH) as an
	// os.Error — surfaced to Lua as "failed to execute"
	return exec_capture(argv[:], "", nil, stdin_data)
}

// makac._ssh_open(name, spec) -> session userdata
// name: session identity, used in errors and the state dir
// <data_dir>/targets/<name>/ (so tame: [A-Za-z0-9._-]).
// spec = { host, user, port?, options? } — options: ssh option overrides,
// string keys to string/number/bool values.
@(private = "file")
_makac_ssh_open :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	name_c: cstring
	{
		l: c.size_t
		s := lua.tolstring(L, 1, &l)
		if s == nil || l == 0 {
			return c.int(lua.L_error(L, "makac._ssh_open: name must be a non-empty string"))
		}
		name_c = s
	}
	name := runtime.cstring_to_string(name_c)
	lua.L_checktype(L, 2, c.int(lua.Type.TABLE))

	data_dir := _data_dir(L)
	if data_dir == "" {
		return c.int(lua.L_error(L, "makac._ssh_open: no data directory (makac.data_dir is unset)"))
	}

	host, host_ok := _opt_string_field(L, 2, "host")
	user, user_ok := _opt_string_field(L, 2, "user")
	if !host_ok || host == "" {
		return c.int(lua.L_error(L, "makac._ssh_open: spec.host must be a non-empty string"))
	}
	if !user_ok || user == "" {
		return c.int(lua.L_error(L, "makac._ssh_open: spec.user must be a non-empty string"))
	}
	// the name becomes a directory under <data_dir>/targets/ — keep it
	// tame (no path traversal, no ':' which makac uses as a separator)
	for r in name {
		if !strings.contains_rune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-", r) {
			return c.int(lua.L_error(L, "makac._ssh_open: invalid name '%s' (allowed: [A-Za-z0-9._-])", name_c))
		}
	}

	port := 22
	if t := lua.getfield(L, 2, "port"); t == c.int(lua.Type.NUMBER) {
		port = int(lua.tointeger(L, -1))
		if port < 1 || port > 65535 {
			lua.pop(L, 1)
			return c.int(lua.L_error(L, "makac._ssh_open: spec.port out of range [1;65535]"))
		}
	} else if t != c.int(lua.Type.NIL) {
		lua.pop(L, 1)
		return c.int(lua.L_error(L, "makac._ssh_open: spec.port must be a number"))
	}
	lua.pop(L, 1)

	// Per-invocation (global) options: connection multiplexing, so the
	// first command authenticates and everything later rides the master.
	global_opts := make(ssh.Option_Table, allocator = context.temp_allocator)
	global_opts["ControlMaster"] = "auto"
	global_opts["ControlPersist"] = "10m"
	// relative → rewritten to an absolute path inside the target's own
	// control-socket directory by generate_config
	global_opts["ControlPath"] = "ctl"
	target_opts := make(ssh.Option_Table, allocator = context.temp_allocator)
	target_opts["HostName"] = host
	target_opts["User"] = user
	// extra ssh options: string keys → scalar values
	if t := lua.getfield(L, 2, "options"); t == c.int(lua.Type.TABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			k: c.size_t
			ks := lua.tolstring(L, -2, &k)
			if ks != nil {
				key := strings.clone(_cstr(ks, k), context.temp_allocator)
				value: ssh.Option_Value
				ok := true
				#partial switch lua.Type(lua.type(L, -1)) {
				case .STRING:
					l: c.size_t
					vs := lua.tolstring(L, -1, &l)
					value = strings.clone(_cstr(vs, l), context.temp_allocator)
				case .BOOLEAN:
					value = bool(lua.toboolean(L, -1))
				case .NUMBER:
					if lua.isinteger(L, -1) {
						value = i64(lua.tointeger(L, -1))
					} else {
						value = f64(lua.tonumber(L, -1))
					}
				case:
					ok = false
				}
				if ok {
					target_opts[key] = value
				}
			}
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1) // options table / nil

	state_dir, _ := os.join_path({data_dir, "targets", name}, context.temp_allocator)
	config_path, gerr := ssh.generate_config(
		state_dir,
		global_opts,
		target_opts,
		context.allocator,
		context.temp_allocator,
	)
	if gerr.kind != .None {
		msg := strings.clone_to_cstring(ssh.error_string(gerr), context.temp_allocator)
		return c.int(lua.L_error(L, "makac._ssh_open: failed to set up session '%s': %s",
			strings.clone_to_cstring(name, context.temp_allocator), msg))
	}

	ud := (^SSH_Session)(lua.newuserdata(L, c.size_t(size_of(SSH_Session))))
	ud^ = SSH_Session {
		name        = strings.clone(name, context.allocator),
		config_path = config_path,
		port        = port,
	}
	lua.L_setmetatable(L, SSH_MT)
	return 1
}

// Type-checked self + open-session guard shared by the methods.
@(private = "file")
_check_session :: proc "c" (L: ^lua.State, op: cstring) -> ^SSH_Session {
	context = runtime.default_context()
	self := (^SSH_Session)(lua.L_checkudata(L, 1, SSH_MT))
	if self.closed {
		lua.L_error(L, "makac.ssh: session '%s' is closed — %s is no longer allowed",
			strings.clone_to_cstring(self.name, context.temp_allocator), op)
		return nil
	}
	return self
}

// sess:run(command, opts?) -> { code, stdout, stderr }
// command is ONE string (ssh passes it to the remote login shell as a single
// word); argv joining/quoting happens on the Lua side. opts.stdin feeds the
// command's stdin (non-interactive).
@(private = "file")
_sess_run :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_session(L, "run")
	if self == nil {return 0}
	l: c.size_t
	cs := lua.L_checkstring(L, 2, &l)
	command := _cstr(cs, l)
	if command == "" {
		return c.int(lua.L_error(L, "makac.ssh: run: command must not be empty"))
	}
	stdin_data: Maybe(string)
	if !lua.isnoneornil(L, 3) {
		lua.L_checktype(L, 3, c.int(lua.Type.TABLE))
		if s, ok := _opt_string_field(L, 3, "stdin"); ok {stdin_data = s}
	}

	port_str := fmt.aprintf("%d", self.port, allocator = context.temp_allocator)
	res, serr := _ssh_capture(
		"ssh",
		{"-F", self.config_path, "-p", port_str, "localhost", command},
		stdin_data,
	)
	if serr != nil {
		return c.int(lua.L_error(L, "makac.ssh: run: failed to execute (is ssh on PATH? host reachable?): %s",
			strings.clone_to_cstring(os.error_string(serr), context.temp_allocator)))
	}
	lua.createtable(L, 0, 3)
	lua.pushinteger(L, lua.Integer(res.code))
	lua.setfield(L, -2, "code")
	_push_lstring(L, res.stdout)
	lua.setfield(L, -2, "stdout")
	_push_lstring(L, res.stderr)
	lua.setfield(L, -2, "stderr")
	return 1
}

// sess:put(local_path, remote_path) — raises on failure.
@(private = "file")
_sess_put :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_session(L, "put")
	if self == nil {return 0}
	local_path := _check_str(L, 2, "put: local path")
	remote := _check_str(L, 3, "put: remote path")

	port_str := fmt.aprintf("%d", self.port, allocator = context.temp_allocator)
	rdest := fmt.aprintf("localhost:%s", remote, allocator = context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "-F", self.config_path, "-P", port_str)
	if os.is_directory(local_path) {append(&args, "-r")}
	append(&args, local_path, rdest)
	res, serr := _ssh_capture("scp", args[:])
	if serr != nil {
		return c.int(lua.L_error(L, "makac.ssh: put: failed to execute scp: %s",
			strings.clone_to_cstring(os.error_string(serr), context.temp_allocator)))
	}
	if res.code != 0 {
		return c.int(lua.L_error(L, "makac.ssh: put: upload failed (exit %d): %s",
			c.int(res.code), strings.clone_to_cstring(res.stderr, context.temp_allocator)))
	}
	return 0
}

// sess:get(remote_path, local_path) — raises on failure.
@(private = "file")
_sess_get :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := _check_session(L, "get")
	if self == nil {return 0}
	remote := _check_str(L, 2, "get: remote path")
	local_path := _check_str(L, 3, "get: local path")

	port_str := fmt.aprintf("%d", self.port, allocator = context.temp_allocator)
	rsrc := fmt.aprintf("localhost:%s", remote, allocator = context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "-F", self.config_path, "-P", port_str, "-r", rsrc, local_path)
	res, serr := _ssh_capture("scp", args[:])
	if serr != nil {
		return c.int(lua.L_error(L, "makac.ssh: get: failed to execute scp: %s",
			strings.clone_to_cstring(os.error_string(serr), context.temp_allocator)))
	}
	if res.code != 0 {
		return c.int(lua.L_error(L, "makac.ssh: get: download failed (exit %d): %s",
			c.int(res.code), strings.clone_to_cstring(res.stderr, context.temp_allocator)))
	}
	return 0
}

// sess:close() — tears down the control master (best-effort) and marks the
// session closed. Idempotent.
@(private = "file")
_sess_close :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^SSH_Session)(lua.L_checkudata(L, 1, SSH_MT))
	if self.closed {return 0}
	self.closed = true
	port_str := fmt.aprintf("%d", self.port, allocator = context.temp_allocator)
	// best-effort: even if this fails (host already gone), the session is
	// closed either way
	_ssh_capture("ssh", {"-F", self.config_path, "-p", port_str, "-O", "exit", "localhost"})
	return 0
}

@(private = "file")
_check_str :: proc "c" (L: ^lua.State, idx: c.int, what: cstring) -> string {
	context = runtime.default_context()
	l: c.size_t
	s := lua.tolstring(L, idx, &l)
	if s == nil || l == 0 {
		lua.L_error(L, "makac.ssh: %s must be a non-empty string", what)
		return ""
	}
	return _cstr(s, l)
}
