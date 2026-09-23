// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import sp "../subprocess"

import lua "vendor:lua/5.4"

// Register the Odin-side primitives available to every VM as makac.*.
register_builtins :: proc(v: ^VM) {
	register(v, "exec", _makac_exec)
	register(v, "download", _makac_download)
	// NB: the flat `listdir` alias is registered by register_fs_primitives
	// (fs.odin), which owns the entry point now.
}

Exec_Result :: struct {
	code:     int,
	stdout:   string,
	stderr:   string,
	// true iff the run was cut short by the timeout (child was TERM/KILLed)
	timed_out: bool,
	// true iff the on_line callback asked to abort (child was TERM/KILLed)
	cb_failed: bool,
}

// Per-line streaming callback. `stream` is "stdout" or "stderr" (always
// "stdout" when the streams are joined). Return false to abort the child
// (TERM, grace, KILL); exec then reports cb_failed. The `ctx` pointer
// round-trips caller state (plain procs: no closure capture).
Exec_Output_Callback :: proc "c" (ctx: rawptr, stream: string, line: string) -> bool

// exec_capture runs `argv` directly (no shell interpretation), capturing
// stdout and stderr separately.
//
// - working_dir (may be "") becomes the child's working directory.
// - env (may be nil) is the child's whole environment; nil inherits ours.
// - stdin_data (may be nil) is written to the child's stdin, which is then
//   closed (non-interactive input).
// - join_stderr (default false) gives the child's stderr the SAME descriptor
//   as stdout (the shell's `2>&1`): stderr text lands in res.stdout in true
//   interleaved order and res.stderr comes back empty.
// - timeout_s (> 0 means armed) bounds the run: on expiry the child gets
//   SIGTERM, a short grace, then SIGKILL; res.timed_out is set. Like a
//   non-zero exit code, a timeout is DATA, not an error.
// - on_line (may be nil) streams complete lines as they arrive, before the
//   captured strings exist; a trailing partial line is flushed at EOF. An
//   on_line that returns false aborts the child (res.cb_failed).
//
// A non-zero exit code is data, not an error; only failing to spawn the
// program at all is an error. The result strings are allocated with
// `allocator` and are owned by the caller.
//
// Implemented as a thin wrapper around `subprocess.Run`; the body lives
// there so `downloader.run_capture` and `ssh.run_process` can share it.
exec_capture :: proc(
	argv: []string,
	working_dir: string = "",
	env: []string = nil,
	stdin_data: Maybe(string) = nil,
	join_stderr: bool = false,
	timeout_s: f64 = 0,
	on_line: Exec_Output_Callback = nil,
	on_line_ctx: rawptr = nil,
	allocator := context.temp_allocator,
) -> (
	res: Exec_Result,
	err: os.Error,
) {
	sub_res, sub_err := sp.Run(argv, sp.Options{
		working_dir    = working_dir,
		env            = env,
		stdin_data     = stdin_data,
		capture_stdout = true,
		capture_stderr = true,
		join_stderr    = join_stderr,
		timeout_s      = timeout_s,
		on_line        = sp.Line_Callback(on_line),
		on_line_ctx    = on_line_ctx,
		allocator      = allocator,
	})
	if sub_err != nil {
		err = sub_err
		return
	}
	res = Exec_Result{
		code       = sub_res.code,
		stdout     = string(sub_res.stdout),
		stderr     = string(sub_res.stderr),
		timed_out  = sub_res.timed_out,
		cb_failed  = sub_res.callback_aborted,
	}
	return
}

// Bridge between exec_capture's plain-proc callback and the Lua function in
// the exec opts: pushes (line, stream), pcall-protected; a Lua error latches
// the message into the state cell and stops emission (the child is aborted by
// exec_capture, this C call raises with the message afterwards).
On_Line_State :: struct {
	L:      ^lua.State,
	cb_idx: c.int,
	failed: bool,
	msg:    string, // owned; deleted by the caller after raising
}

@(private = "file")
_on_line_bridge :: proc "c" (ctx: rawptr, stream: string, line: string) -> bool {
	context = runtime.default_context()
	st := (^On_Line_State)(ctx)
	lua.pushvalue(st.L, st.cb_idx)
	_push_lstring(st.L, line)
	_push_lstring(st.L, stream)
	if lua.pcall(st.L, 2, 0, 0) != c.int(lua.Status.OK) {
		if s := lua.tostring(st.L, -1); s != nil {
			st.msg = strings.clone_from_cstring(s, context.allocator)
		}
		lua.pop(st.L, 1)
		st.failed = true
		return false
	}
	return true
}

// makac.exec(argv, opts) -> { code, stdout, stderr, timed_out }
//
// argv: array of strings; argv[1] is the program, run directly (no shell).
// opts: optional table:
//   chdir (string), env (string->string table merged on top of the current
//   environment), stdin (string data, non-interactive); join (bool: stderr
//   lands in stdout in true interleaved order — the shell's `2>&1`;
//   result.stderr is then empty); timeout_s (number: on expiry the child is
//   SIGTERM'd, given a 1s grace, then SIGKILL'd; result.timed_out is then
//   true); on_line (function(line, stream): complete lines as they arrive,
//   stream "stdout"/"stderr"; an error in the callback aborts the child and
//   propagates as the exec error).
// Non-zero exit codes and timeouts are DATA, not errors; only failing to
// spawn the program at all (or an on_line failure) raises.
@(private = "file")
_makac_exec :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	lua.L_checktype(L, 1, c.int(lua.Type.TABLE))

	argv := make([dynamic]string, context.temp_allocator)
	n := int(lua.rawlen(L, 1))
	for i in 1 ..= n {
		lua.rawgeti(L, 1, lua.Integer(i))
		l: c.size_t
		s := lua.tolstring(L, -1, &l)
		if s == nil {
			return c.int(lua.L_error(L, "makac.exec: argv[%d] must be a string", i))
		}
		append(&argv, _cstr(s, l))
		lua.pop(L, 1)
	}
	if len(argv) == 0 {
		return c.int(lua.L_error(L, "makac.exec: argv must not be empty"))
	}

	chdir := ""
	stdin_data: Maybe(string)
	env: []string
	join := false
	timeout_s := 0.0
	on_line_cb: Exec_Output_Callback = nil
	// the bridge's state cell: the Lua function's stack slot, and the error
	// the bridge latches when a callback fails
	cb_state := new_clone(On_Line_State{L = L}, context.temp_allocator)

	if !lua.isnoneornil(L, 2) {
		lua.L_checktype(L, 2, c.int(lua.Type.TABLE))
		if s, ok := _opt_string_field(L, 2, "chdir"); ok {chdir = s}
		if s, ok := _opt_string_field(L, 2, "stdin"); ok {stdin_data = s}
		if t := lua.getfield(L, 2, "join"); t != c.int(lua.Type.NIL) {
			join = bool(lua.toboolean(L, -1))
		}
		lua.pop(L, 1) // join

		if t := lua.getfield(L, 2, "timeout_s"); t == c.int(lua.Type.NUMBER) {
			timeout_s = f64(lua.tonumber(L, -1))
			lua.pop(L, 1)
			if timeout_s < 0 {
				return c.int(lua.L_error(L, "makac.exec: opts.timeout_s must not be negative"))
			}
		} else if t != c.int(lua.Type.NIL) {
			lua.pop(L, 1)
			return c.int(lua.L_error(L, "makac.exec: opts.timeout_s must be a number (seconds)"))
		} else {
			lua.pop(L, 1)
		}

		if t := lua.getfield(L, 2, "on_line"); t == c.int(lua.Type.FUNCTION) {
			cb_state.cb_idx = lua.absindex(L, -1) // left ON the stack: GC-safety
			on_line_cb = _on_line_bridge
			// NB: do NOT pop — cb_idx must stay a live stack slot through the call
		} else if t != c.int(lua.Type.NIL) {
			lua.pop(L, 1)
			return c.int(lua.L_error(L, "makac.exec: opts.on_line must be a function(line, stream)"))
		} else {
			lua.pop(L, 1)
		}

		if lua.Type(lua.getfield(L, 2, "env")) == .TABLE {
			overrides := make([dynamic]string, 0, 0, context.temp_allocator)
			lua.pushnil(L)
			for lua.next(L, -2) != 0 {
				kl, vl: c.size_t
				k := lua.tolstring(L, -2, &kl)
				v := lua.tolstring(L, -1, &vl)
				if k != nil && v != nil {
					append(&overrides, fmt.tprintf("%s=%s", _cstr(k, kl), _cstr(v, vl)))
				}
				lua.pop(L, 1)
			}
			lua.pop(L, 1) // env table
			env = _merge_env(overrides[:])
		} else {
			lua.pop(L, 1) // whatever 'env' was
		}
	}

	res, spawn_err := exec_capture(argv[:], chdir, env, stdin_data, join, timeout_s, on_line_cb, cb_state)
	if spawn_err != nil {
		msg := strings.clone_to_cstring(os.error_string(spawn_err), context.temp_allocator)
		arg0 := strings.clone_to_cstring(argv[0], context.temp_allocator)
		return c.int(lua.L_error(L, "makac.exec: failed to spawn '%s': %s", arg0, msg))
	}
	if cb_state.failed {
		msg := strings.clone_to_cstring(cb_state.msg, context.temp_allocator)
		if cb_state.msg != "" {delete(cb_state.msg, context.allocator)}
		return c.int(lua.L_error(L, "makac.exec: on_line callback failed: %s", msg))
	}

	lua.createtable(L, 0, 4)
	lua.pushinteger(L, lua.Integer(res.code))
	lua.setfield(L, -2, "code")
	_push_lstring(L, res.stdout)
	lua.setfield(L, -2, "stdout")
	_push_lstring(L, res.stderr)
	lua.setfield(L, -2, "stderr")
	lua.pushboolean(L, b32(res.timed_out))
	lua.setfield(L, -2, "timed_out")
	return 1
}

// Convert a Lua string pointer+length to an Odin string (no copy).
_cstr :: proc "contextless" (s: cstring, l: c.size_t) -> string {
	return string(([^]u8)(s)[:int(l)])
}

// Push a (possibly empty) Odin string on the Lua stack.
_push_lstring :: proc "c" (L: ^lua.State, s: string) {
	if len(s) == 0 {
		lua.pushlstring(L, "", 0)
	} else {
		lua.pushlstring(L, cstring(raw_data(s)), c.size_t(len(s)))
	}
}

// Get an optional string field of the table at `idx`.
_opt_string_field :: proc "c" (L: ^lua.State, idx: c.int, field: cstring) -> (string, bool) {
	t := lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if t != c.int(lua.Type.STRING) {
		return "", false
	}
	l: c.size_t
	s := lua.tolstring(L, -1, &l)
	return _cstr(s, l), true
}

// Merge `KEY=VALUE` overrides on top of the current process environment.
// Allocated from the temp allocator.
_merge_env :: proc(overrides: []string) -> []string {
	if len(overrides) == 0 {
		return nil
	}
	base, _ := os.environ(context.temp_allocator)
	merged := make([dynamic]string, 0, len(base) + len(overrides), context.temp_allocator)
	append(&merged, ..base)
	outer: for ov in overrides {
		eq := strings.index_byte(ov, '=')
		prefix := ov[:eq + 1] // includes '='
		for &e in merged {
			if strings.has_prefix(e, prefix) {
				e = ov
				continue outer
			}
		}
		append(&merged, ov)
	}
	return merged[:]
}
