// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:time"

import lua "vendor:lua/5.4"

// Register the Odin-side primitives available to every VM as makac.*.
register_builtins :: proc(v: ^VM) {
	register(v, "exec", _makac_exec)
	register(v, "fetch", _makac_fetch)
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
	stdout_r, stdout_w := os.pipe() or_return
	defer os.close(stdout_r)
	stderr_r, stderr_w := os.pipe() or_return
	defer os.close(stderr_r)

	// join_stderr (the shell's `2>&1`): the child's stderr writes into
	// stdout's pipe — one stream, true interleaved order. The (unused)
	// stderr pipe is created and closed exactly as in the split-stream case;
	// the plain path is byte-for-byte the original behavior.
	child_stderr_w := stderr_w
	if join_stderr {child_stderr_w = stdout_w}

	stdin_r: ^os.File
	stdin_w: ^os.File
	if _, has_stdin := stdin_data.?; has_stdin {
		stdin_r, stdin_w = os.pipe() or_return
	}
	defer if stdin_r != nil {os.close(stdin_r)}

	p: os.Process
	{
		// Once spawned, the child holds its own copies of the write-end
		// descriptors; drop the parent's so our read ends see EOF when the
		// child exits. (NB: defers are block-scoped; this bare block ends
		// right after process_start.)
		defer os.close(stdout_w)
		defer os.close(stderr_w)
		pp, perr := os.process_start(
			os.Process_Desc{
				working_dir = working_dir,
				command     = argv,
				env         = env,
				stdin       = stdin_r,
				stdout      = stdout_w,
				stderr      = child_stderr_w,
			},
		)
		if perr != nil {
			if stdin_w != nil {os.close(stdin_w)}
			err = perr
			return
		}
		p = pp
	}

	if data, has_stdin := stdin_data.?; has_stdin {
		// Closing the (only remaining) write end signals EOF to the child.
		defer os.close(stdin_w)
		// NOTE: writing more than the pipe buffer holds can block if the
		// child never reads stdin; makac exec input is expected to be small,
		// non-interactive data. EPIPE (child exited without reading) just
		// ends the write; SIGPIPE is ignored at VM creation.
		rest := transmute([]u8)data
		for len(rest) > 0 {
			n, werr := os.write(stdin_w, rest)
			if werr != nil {break}
			rest = rest[n:]
		}
	}

	stdout_b := make([dynamic]u8, allocator)
	stderr_b := make([dynamic]u8, allocator)
	buf: [4096]u8 = ---
	stdout_done := false
	stderr_done := join_stderr // joined: no separate stderr to drain

	// Line emission state: the bridge callback + its user pointer, and the
	// latch set when a callback returns false (no further lines are emitted
	// once stopped; the child is being shut down anyway).
	Line_Feeder :: struct {
		cb:      Exec_Output_Callback,
		ctx:     rawptr,
		stopped: bool,
	}
	out_fdr := Line_Feeder{cb = on_line, ctx = on_line_ctx}

	// Per-stream partial line accumulated between on_line emissions.
	// (Captures stay complete regardless; these are the streaming view only.)
	out_line := make([dynamic]u8, context.temp_allocator)
	err_line := make([dynamic]u8, context.temp_allocator)

	// Emit every complete ('\n'-terminated) line in acc.
	feed :: proc(acc: ^[dynamic]u8, chunk: []u8, stream: string, fdr: ^Line_Feeder) {
		if fdr.cb == nil || fdr.stopped {return}
		append(acc, ..chunk)
		start := 0
		for i in 0 ..< len(acc) {
			if acc[i] != '\n' {continue}
			if !fdr.cb(fdr.ctx, stream, string(acc[start:i])) {
				fdr.stopped = true
				clear(acc)
				return
			}
			start = i + 1
		}
		// drop consumed lines
		copy(acc[:], acc[start:])
		resize(acc, len(acc) - start)
	}
	// Flush an unterminated tail at EOF.
	flush :: proc(acc: ^[dynamic]u8, stream: string, fdr: ^Line_Feeder) {
		if fdr.cb == nil || fdr.stopped || len(acc) == 0 {return}
		if !fdr.cb(fdr.ctx, stream, string(acc[:])) {fdr.stopped = true}
		clear(acc)
	}

	// 0 = running; 1 = SIGTERM sent, grace deadline armed; 2 = SIGKILL sent
	escalation := 0
	timed := timeout_s > 0
	deadline := time.time_add(time.now(), time.Duration(timeout_s * 1e9))

	for !stdout_done || !stderr_done {
		posix_fd :: proc(f: ^os.File) -> posix.FD {return posix.FD(i32(os.fd(f)))}
		fds: [2]posix.pollfd
		nfds := 0
		if !stdout_done {fds[nfds] = {fd = posix_fd(stdout_r), events = {.IN}}; nfds += 1}
		if !stderr_done {fds[nfds] = {fd = posix_fd(stderr_r), events = {.IN}}; nfds += 1}

		ms := i32(-1)
		if timed {
			rem := time.duration_milliseconds(time.diff(time.now(), deadline))
			ms = rem > 0 ? i32(rem) : 0
		}
		n := posix.poll(&fds[0], auto_cast nfds, ms)
		if n < 0 {
			err = os.Platform_Error(posix.errno())
			return
		}
		if n == 0 {
			// poll timeout: only reachable with a deadline armed
			switch escalation {
			case 0:
				res.timed_out = true
				_ = os.process_terminate(p) // SIGTERM
				deadline = time.time_add(time.now(), time.Second)
				escalation = 1
			case:
				_ = os.process_kill(p) // no more grace
				timed = false          // past this point we wait for EOF indefinitely
				escalation = 2
			}
			continue
		}

		handle :: proc(
			pfd: ^posix.pollfd,
			f: ^os.File,
			accum, line_acc: ^[dynamic]u8,
			done: ^bool,
			stream: string,
			fdr: ^Line_Feeder,
			readbuf: []u8,
		) {
			if done^ {return}
			if .IN in pfd.revents {
				n, rerr := os.read(f, readbuf)
				if rerr == nil && n > 0 {
					append(accum, ..readbuf[:n])
					feed(line_acc, readbuf[:n], stream, fdr)
					return
				}
				// EOF or read error: the stream is over either way
				flush(line_acc, stream, fdr)
				done^ = true
				return
			}
			if pfd.revents & {.HUP, .ERR, .NVAL} != {} {
				flush(line_acc, stream, fdr)
				done^ = true
			}
		}

		wi := 0
		if !stdout_done {
			handle(&fds[0], stdout_r, &stdout_b, &out_line, &stdout_done, "stdout", &out_fdr, buf[:])
			wi = 1
		}
		if !stderr_done {
			handle(&fds[wi], stderr_r, &stderr_b, &err_line, &stderr_done, "stderr", &out_fdr, buf[:])
		}

		if out_fdr.stopped {
			// the callback asked to stop: shut the child down, then drain the
			// residue quietly until the pipes close
			res.cb_failed = true
			_ = os.process_terminate(p)
			_ = os.process_kill(p)
			timed = false
		}
	}

	state := os.process_wait(p) or_return
	res.code = state.exit_code
	res.stdout = string(stdout_b[:])
	res.stderr = string(stderr_b[:])
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
