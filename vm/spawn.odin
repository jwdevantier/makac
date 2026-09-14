// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

import lua "vendor:lua/5.4"

// makac.spawn (design/stdlib.md, "Processes (flat — orchestrator
// vocabulary)" and "Launching long-lived processes (QEMU)"). fork a child
// whose lifetime nobody manages, for processes that must outlive the run:
//
//   makac.spawn(argv, { stdout = <path>, stderr = <path>, chdir?, env? }) -> proc
//     proc.pid      -> integer
//     proc:status() -> "running" | { code = }  -- waitpid(WNOHANG); reaps once exited
//
// Hard rules of detached spawning, per spec:
// * stdio goes to FILES, never pipes — a pipe reader would block for the
//   child's whole lifetime. stdin is /dev/null (fs.null_file()).
// * stdout/stderr opts are required, string-or-path each.
// * There is deliberately no :kill (`exec {"kill", ...}` covers it) and the
//   object NEVER kills on GC.
// * status() reaps once the child has exited, then reports the cached
//   result; while running it reports the string "running".

SPAWN_MT :: "makac.proc"

Spawn_Object :: struct {
	pid:    posix.pid_t,
	cmd:    string, // argv joined, owned; for __tostring/errors
	reaped: bool,   // waitpid has reclaimed the child; `code` is final
	code:   int,    // exit status, or 128+signal when terminated by a signal
}

register_spawn_primitives :: proc(v: ^VM) {
	L := v.state
	if lua.L_newmetatable(L, SPAWN_MT) != 0 {
		lua.pushcclosure(L, _spawn_index, 0)
		lua.setfield(L, -2, "__index")
		lua.pushcclosure(L, _spawn_gc, 0)
		lua.setfield(L, -2, "__gc")
		lua.pushcclosure(L, _spawn_tostring, 0)
		lua.setfield(L, -2, "__tostring")
	}
	lua.pop(L, 1)
	register(v, "spawn", _makac_spawn)
}

@(private = "file")
_spawn_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Spawn_Object)(lua.L_checkudata(L, 1, SPAWN_MT))
	if lua.Type(lua.type(L, 2)) != .STRING {
		lua.pushnil(L)
		return 1
	}
	switch runtime.cstring_to_string(lua.tostring(L, 2)) {
	case "pid":
		lua.pushinteger(L, lua.Integer(self.pid))
	case "status":
		lua.pushcclosure(L, _proc_status, 0)
	case:
		lua.pushnil(L)
	}
	return 1
}

// __gc: NEVER kills the child (spec) — reaping a still-running child would
// block anyway; an orphan is inherited and reaped by init once makac exits.
// The only work here is freeing the owned label.
@(private = "file")
_spawn_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Spawn_Object)(lua.L_checkudata(L, 1, SPAWN_MT))
	if self.cmd != "" {delete(self.cmd, context.allocator)}
	self^ = {}
	return 0
}

@(private = "file")
_spawn_tostring :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Spawn_Object)(lua.L_checkudata(L, 1, SPAWN_MT))
	label := strings.clone_to_cstring(self.cmd, context.temp_allocator)
	lua.pushfstring(L, "makac.proc: pid %d (%s)", c.int(self.pid), label)
	return 1
}

// opts.<field> — string-or-path, required. Returns an owned cstring (temp
// allocator) so the Lua value can be dropped from the stack immediately.
@(private = "file")
_req_path_field :: proc "c" (L: ^lua.State, idx: c.int, field: cstring) -> cstring {
	context = runtime.default_context()
	t := lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if lua.Type(t) != .STRING && lua.Type(t) != .USERDATA {
		lua.L_error(L, "makac.spawn: opts.%s (string or path) is required", field)
		return nil
	}
	s := check_path_string(L, -1) // anchored by the stack slot until we clone
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// Opt variant: nil/absent means "no override".
@(private = "file")
_opt_path_field :: proc "c" (L: ^lua.State, idx: c.int, field: cstring) -> cstring {
	context = runtime.default_context()
	t := lua.getfield(L, idx, field)
	defer lua.pop(L, 1)
	if lua.Type(t) == .NIL {return nil}
	if lua.Type(t) != .STRING && lua.Type(t) != .USERDATA {
		lua.L_error(L, "makac.spawn: opts.%s must be a string or path", field)
		return nil
	}
	s := check_path_string(L, -1)
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// Resolve `file` against PATH the way execvp does, so the child can use
// execve with an explicit environment. Runs in the PARENT (before fork) —
// the child makes no allocations. Returns `file` unchanged when it names a
// path or nothing is found (execve then fails and the child exits 127).
@(private = "file")
_resolve_exec_path :: proc(file: string, envp: []string) -> string {
	if strings.contains(file, "/") {return file}
	path_env := ""
	for e in envp {
		if strings.has_prefix(e, "PATH=") {path_env = e[5:]; break}
	}
	if path_env == "" {
		path_env = os.get_env_alloc("PATH", context.temp_allocator)
	}
	if path_env == "" {path_env = "/bin:/usr/bin"}
	dirs := strings.split(path_env, ":", context.temp_allocator)
	for d in dirs {
		dir := d == "" ? "." : d
		candidate := strings.join({dir, file}, "/", context.temp_allocator)
		if os.exists(candidate) && !os.is_dir(candidate) {return candidate}
	}
	return file
}

@(private = "file")
_makac_spawn :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checktype(L, 1, c.int(lua.Type.TABLE))
	lua.L_checktype(L, 2, c.int(lua.Type.TABLE))

	// argv — array of strings, non-empty (same discipline as makac.exec).
	argv := make([dynamic]string, 0, 4, context.temp_allocator)
	n := int(lua.rawlen(L, 1))
	for i in 1 ..= n {
		lua.rawgeti(L, 1, lua.Integer(i))
		l: c.size_t
		s := lua.tolstring(L, -1, &l)
		if s == nil {
			return c.int(lua.L_error(L, "makac.spawn: argv[%d] must be a string", i))
		}
		append(&argv, _cstr(s, l))
		lua.pop(L, 1)
	}
	if len(argv) == 0 {
		return c.int(lua.L_error(L, "makac.spawn: argv must not be empty"))
	}

	// opts: stdout/stderr (required string-or-path), chdir?, env? — env has
	// exec's merge-over-our-environment semantics.
	stdout_cs := _req_path_field(L, 2, "stdout")
	if stdout_cs == nil {return 0}
	stderr_cs := _req_path_field(L, 2, "stderr")
	if stderr_cs == nil {return 0}
	chdir_cs := _opt_path_field(L, 2, "chdir")

	env: []string
	if lua.Type(lua.getfield(L, 2, "env")) == .TABLE {
		overrides := make([dynamic]string, 0, 0, context.temp_allocator)
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			kl, vl: c.size_t
			k := lua.tolstring(L, -2, &kl)
			vp := lua.tolstring(L, -1, &vl)
			if k != nil && vp != nil {
				append(&overrides, fmt.tprintf("%s=%s", _cstr(k, kl), _cstr(vp, vl)))
			}
			lua.pop(L, 1)
		}
		lua.pop(L, 1) // env table
		env = _merge_env(overrides[:])
	} else {
		lua.pop(L, 1) // whatever 'env' was
	}

	// Marshal exec arguments NOW, in the parent: after fork the child does
	// syscalls only (no allocation — the copied allocator state is not to be
	// trusted in an exec boundary).
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	cargv[len(argv)] = nil

	exe := cargv[0]
	cenvp: []cstring
	if env != nil {
		resolved := _resolve_exec_path(argv[0], env)
		exe = strings.clone_to_cstring(resolved, context.temp_allocator)
		cenvp = make([]cstring, len(env) + 1, context.temp_allocator)
		for e, i in env {
			cenvp[i] = strings.clone_to_cstring(e, context.temp_allocator)
		}
		cenvp[len(env)] = nil
	}

	// stdio FILES (the one hard rule: never pipes) — open failures raise;
	// L_error longjmps, so every later failure path closes explicitly.
	open_mode :: posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}
	out_fd := posix.open(stdout_cs, {.WRONLY, .CREAT, .APPEND}, open_mode)
	if out_fd == posix.FD(-1) {
		err := strings.clone_to_cstring(os.error_string(os.Platform_Error(posix.errno())), context.temp_allocator)
		return c.int(lua.L_error(L, "makac.spawn: cannot open stdout '%s': %s", stdout_cs, err))
	}
	err_fd := posix.open(stderr_cs, {.WRONLY, .CREAT, .APPEND}, open_mode)
	if err_fd == posix.FD(-1) {
		err := strings.clone_to_cstring(os.error_string(os.Platform_Error(posix.errno())), context.temp_allocator)
		_ = posix.close(out_fd)
		return c.int(lua.L_error(L, "makac.spawn: cannot open stderr '%s': %s", stderr_cs, err))
	}
	in_fd := posix.open("/dev/null", posix.O_Flags{})
	if in_fd == posix.FD(-1) {
		err := strings.clone_to_cstring(os.error_string(os.Platform_Error(posix.errno())), context.temp_allocator)
		_ = posix.close(out_fd)
		_ = posix.close(err_fd)
		return c.int(lua.L_error(L, "makac.spawn: cannot open /dev/null: %s", err))
	}

	pid := posix.fork()
	if pid < 0 {
		// explicit close: L_error longjmps past any defer
		_ = posix.close(in_fd)
		_ = posix.close(out_fd)
		_ = posix.close(err_fd)
		err := strings.clone_to_cstring(os.error_string(os.Platform_Error(posix.errno())), context.temp_allocator)
		return c.int(lua.L_error(L, "makac.spawn: fork failed: %s", err))
	}
	if pid == 0 {
		// CHILD — no allocation, no Lua, syscalls only. Wire the files onto
		// 0/1/2, chdir if asked, exec. Exec failure: the stderr file holds
		// nothing extra, so the exit code alone carries the signal (127).
		_ = posix.dup2(in_fd, posix.FD(0))
		_ = posix.dup2(out_fd, posix.FD(1))
		_ = posix.dup2(err_fd, posix.FD(2))
		_ = posix.close(in_fd)
		_ = posix.close(out_fd)
		_ = posix.close(err_fd)
		if chdir_cs != nil {
			if posix.chdir(chdir_cs) != .OK {posix._exit(126)}
		}
		if cenvp != nil {
			_ = posix.execve(exe, &cargv[0], &cenvp[0])
		} else {
			_ = posix.execvp(exe, &cargv[0])
		}
		posix._exit(127)
	}

	// PARENT — the child holds its own copies; drop ours.
	_ = posix.close(in_fd)
	_ = posix.close(out_fd)
	_ = posix.close(err_fd)

	label := strings.join(argv[:], " ", context.temp_allocator)
	ud := (^Spawn_Object)(lua.newuserdata(L, c.size_t(size_of(Spawn_Object))))
	ud^ = Spawn_Object {
		pid    = pid,
		cmd    = strings.clone(label, context.allocator),
		reaped = false,
		code   = 0,
	}
	lua.L_setmetatable(L, SPAWN_MT)
	return 1
}

// proc:status() -> "running" | { code = } — one waitpid(WNOHANG); once the
// child has exited it is REAPED and the cached result is reported on every
// later call. A signal termination reports 128+signum (shell convention).
@(private = "file")
_proc_status :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Spawn_Object)(lua.L_checkudata(L, 1, SPAWN_MT))
	if !self.reaped {
		st: c.int
		r := posix.waitpid(self.pid, &st, {.NOHANG})
		if r == self.pid {
			self.reaped = true
			if posix.WIFEXITED(st) {
				self.code = int(posix.WEXITSTATUS(st))
			} else if posix.WIFSIGNALED(st) {
				self.code = 128 + int(posix.WTERMSIG(st))
			} else {
				// neither exited nor signaled and WNOHANG matched — only
				// possible with stopped/continued flags we never set
				self.code = -1
			}
		} else if r < 0 {
			err := strings.clone_to_cstring(os.error_string(os.Platform_Error(posix.errno())), context.temp_allocator)
			return c.int(lua.L_error(L, "makac.proc: status: waitpid failed: %s", err))
		}
		// r == 0: still running
	}
	if self.reaped {
		lua.createtable(L, 0, 1)
		lua.pushinteger(L, lua.Integer(self.code))
		lua.setfield(L, -2, "code")
	} else {
		lua.pushliteral(L, "running")
	}
	return 1
}
