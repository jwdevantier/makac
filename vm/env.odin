// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

import lua "vendor:lua/5.4"

// makac.env (design2/stdlib.md, "makac.env") — the process-environment and
// makac-identity submodule:
//
//   makac.env.all() -> { NAME = value, ... }   -- whole process environment
//   makac.env.version() -> major, minor        -- build-time constants below
//   makac.env.makac_path() -> path             -- /proc/self/exe, as a path
//
// `all` enumerates core:os.environ ("key=value" strings) into a Lua table.
// There is deliberately NO `set` counterpart: per-command environments
// belong to exec's `env` option; mutating process-wide state mid-workflow
// is a footgun nothing needs.
//
// The VERSION_* constants are the single source of truth for makac's
// version: `makac.env.version()` reports them and the root command's
// `--version` flag (main.odin) prints the same pair. Scheme (htt,
// verbatim): MAJOR increments on incompatible changes to EXISTING APIs,
// MINOR on added APIs; while major is 0, minor bumps may include
// incompatible changes — the discipline starts at 1.0.
VERSION_MAJOR :: 0
VERSION_MINOR :: 3

register_env_primitives :: proc(v: ^VM) {
	L := v.state
	_push_submodule(v, "env")
	defer lua.pop(L, 1)
	lua.pushcclosure(L, _makac_env_all, 0)
	lua.setfield(L, -2, "all")
	lua.pushcclosure(L, _makac_env_version, 0)
	lua.setfield(L, -2, "version")
	lua.pushcclosure(L, _makac_env_makac_path, 0)
	lua.setfield(L, -2, "makac_path")
}

// makac.env.all() -> { NAME = value, ... } — the whole process environment
// as a table. Entries are "key=value" (core:os.environ); the split is at
// the FIRST '=' (values may contain '='; names cannot). Uses raw table
// sets with length-checked strings — environment values can hold any byte
// sequence short of NUL.
@(private = "file")
_makac_env_all :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	envs, err := os.environ(context.temp_allocator)
	if err != nil {
		errmsg := fmt.tprintf("cannot enumerate environment: %v", err)
		return c.int(lua.L_error(L, "makac.env: all: %s", cstring(raw_data(errmsg))))
	}
	lua.createtable(L, 0, c.int(len(envs)))
	for e in envs {
		eq := strings.index_byte(e, '=')
		if eq < 0 {
			continue // defensive: POSIX guarantees name=value
		}
		key := e[:eq]
		val := e[eq + 1:]
		lua.pushlstring(L, cstring(raw_data(key)), c.size_t(len(key)))
		lua.pushlstring(L, cstring(raw_data(val)), c.size_t(len(val)))
		lua.settable(L, -3)
	}
	return 1
}

// makac.env.version() -> major, minor — the build-time constants above,
// as Lua integers (capability pinning for workflows).
@(private = "file")
_makac_env_version :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.pushinteger(L, lua.Integer(VERSION_MAJOR))
	lua.pushinteger(L, lua.Integer(VERSION_MINOR))
	return 2
}

// makac.env.makac_path() -> path — absolute, canonicalized path of the
// running makac binary (core:os.get_executable_path; /proc/self/exe on
// Linux) as a `path` value. For re-invoking makac in an isolated process
// without trusting $PATH.
@(private = "file")
_makac_env_makac_path :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	path, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		errmsg := fmt.tprintf("cannot resolve executable path: %v", err)
		return c.int(lua.L_error(L, "makac.env: makac_path: %s", cstring(raw_data(errmsg))))
	}
	_push_path(L, path)
	return 1
}
