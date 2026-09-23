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

// VM wraps a Lua 5.4 state. It is a struct (not a bare ^lua.State) so that
// later tasks can hang makac-specific state off it (registered Odin-side
// primitives, the data directory, ...).
VM :: struct {
	state:    ^lua.State,
	// The resolved `.makac` data directory ("" when the VM is data-dir-less,
	// e.g. in plain unit tests). Also mirrored into the Lua registry under
	// DATA_DIR_REGKEY so C primitives (makac.download, ...) can reach it from a
	// bare ^lua.State. Owned by the VM; freed by `close`.
	data_dir: string,
}

// Create a new Lua state with the full standard library opened. `data_dir`
// (optional) is the resolved `.makac` directory; Odin-side primitives that
// need it (makac.download) raise a clear error when it is absent.
// Returns nil if the state could not be allocated.
new :: proc(data_dir: string = "") -> ^VM {
	state := lua.L_newstate()
	if state == nil {
		return nil
	}
	lua.L_openlibs(state)
	// Writing to a spawned child's stdin after the child already exited
	// must surface as EPIPE (handled in code), not kill the whole makac
	// process with SIGPIPE.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	v := new_clone(VM{state = state, data_dir = ""})
	if data_dir != "" {
		v.data_dir = strings.clone(data_dir)
		lua.pushlstring(
			state,
			cstring(raw_data(v.data_dir)),
			c.size_t(len(v.data_dir)),
		)
		lua.setfield(state, lua.REGISTRYINDEX, DATA_DIR_REGKEY)
	}
	// The data directory is reachable by C primitives via DATA_DIR_REGKEY in
	// the Lua registry; session/client primitives (ssh, qmp) are self-contained
	// userdata and need no VM-side registry.
	register_builtins(v)
	register_ssh_primitives(v)
	register_qmp_primitives(v)
	register_time_primitives(v)
	register_json_primitives(v)
	register_fs_primitives(v)
	register_env_primitives(v)
	register_proc_primitives(v)
	register_spawn_primitives(v)
	register_random_primitives(v)
	// The embedded prelude defines the workflow DSL every script relies on;
	// evaluate it now so no user-facing Lua can run before it exists.
	must_init_prelude(v)
	// the embedded LuaCATS stub, read back by makac.luals_setup (design/luacats.md)
	expose_luals_stub(v)
	// expose the data directory as makac.data_dir (Lua helpers like
	// fetch_all/read_package_defs default to it); may be the empty string
	lua.getglobal(state, "makac")
	lua.pushlstring(state, cstring(raw_data(v.data_dir)), c.size_t(len(v.data_dir)))
	lua.setfield(state, -2, "data_dir")
	lua.pop(state, 1)
	return v
}

// Destroy the VM and its underlying Lua state.
close :: proc(v: ^VM) {
	if v == nil {
		return
	}
	if v.state != nil {
		lua.close(v.state) // runs __gc on surviving ssh/qmp userdata
		v.state = nil
	}
	if v.data_dir != "" {
		delete(v.data_dir)
	}
	free(v)
}

// Error information returned by run_string. `message` is heap-allocated with
// context.allocator; callers should `delete` it when done.
Error :: struct {
	message: string,
}

// Evaluate Lua source `src` in the VM. `chunk_name` labels the chunk in error
// messages (convention: "@file.lua" for files). Returns a non-empty Error on
// compile (syntax) or runtime failure; the error message from the Lua stack is
// preserved verbatim in `err.message`, never swallowed.
run_string :: proc(v: ^VM, src: string, chunk_name: string = "chunk") -> (err: Error, ok: bool) {
	L := v.state
	name := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	status := lua.L_loadbuffer(L, raw_data(src), c.size_t(len(src)), name)
	if status != .OK {
		return {message = _pop_error_message(L)}, false
	}
	if lua.pcall(L, 0, 0, 0) != c.int(lua.Status.OK) {
		return {message = _pop_error_message(L)}, false
	}
	return {}, true
}

// Copy the error message on top of the Lua stack, then pop it.
_pop_error_message :: proc(L: ^lua.State) -> string {
	msg := "<no error message>"
	if s := lua.tostring(L, -1); s != nil {
		msg = strings.clone_from_cstring(s)
	}
	lua.pop(L, 1)
	return msg
}

// Load and evaluate the Lua file at `path`. The chunk is named "@path" so that
// error messages and tracebacks refer to the file. Missing/unreadable files
// are reported as errors.
run_file :: proc(v: ^VM, path: string) -> (err: Error, ok: bool) {
	src, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		err.message = fmt.aprintf("cannot read file '%s': %s", path, os.error_string(read_err))
		return err, false
	}
	chunk_name := fmt.aprintf("@%s", path, allocator = context.temp_allocator)
	return run_string(v, string(src), chunk_name)
}

// Call the Lua function at dotted path `name` (e.g. "makac.close_all_targets")
// with no arguments IF it exists and is a function. Returns called=false when
// the path does not resolve to a function. A runtime error inside the call is
// surfaced in err (never swallowed); the message is heap-allocated — the
// caller must delete it (Error.message semantics, see run_string).
call_named :: proc(v: ^VM, name: string) -> (called: bool, err: Error) {
	L := v.state
	top := lua.gettop(L)
	defer lua.settop(L, top) // balanced, also on the error path

	parts := strings.split(name, ".", context.temp_allocator)
	if len(parts) == 0 {return false, {}}
	if lua.Type(lua.getglobal(L, strings.clone_to_cstring(parts[0], context.temp_allocator))) == .NIL {
		return false, {}
	}
	for part in parts[1:] {
		if lua.Type(lua.type(L, -1)) != .TABLE {
			return false, {}
		}
		lua.getfield(L, -1, strings.clone_to_cstring(part, context.temp_allocator))
		lua.remove(L, -2) // drop the intermediate table, keep the field value
	}
	if lua.Type(lua.type(L, -1)) != .FUNCTION {
		return false, {}
	}
	if lua.pcall(L, 0, 0, 0) != c.int(lua.Status.OK) {
		return true, {message = _pop_error_message(L)}
	}
	return true, {}
}
