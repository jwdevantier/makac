// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
package vm

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

import lua "vendor:lua/5.4"

// makac.env (design/stdlib.md): all() enumerates the process environment,
// version() returns the build-time constants, makac_path() is the absolute
// path of the running binary as a `path` value.

@(test)
test_env_all_contains_sentinel :: proc(t: ^testing.T) {
	// Set a sentinel in the TEST process's environment; the VM primitive
	// enumerates the same process, so the table must carry it verbatim.
	serr := os.set_env("MAKAC_ENV_TEST_SENTINEL", "sentinel-value-7f3a")
	testing.expect(t, serr == nil, "set_env failed")
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local env = makac.env.all()
		assert(type(env) == "table", "all() returns a table")
		assert(env.MAKAC_ENV_TEST_SENTINEL == "sentinel-value-7f3a",
			"sentinel env var must appear verbatim")
		-- PATH is effectively always present; a value containing '=' must
		-- survive the first-'=' split intact.
		assert(type(env.PATH) == "string", "PATH must be present")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_env_all_splits_at_first_equals :: proc(t: ^testing.T) {
	serr := os.set_env("MAKAC_ENV_TEST_EQUALS", "a=b=c")
	testing.expect(t, serr == nil, "set_env failed")
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local env = makac.env.all()
		assert(env.MAKAC_ENV_TEST_EQUALS == "a=b=c",
			"split at first '=' only; value keeps the rest")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_env_version_matches_constants :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local major, minor = makac.env.version()
		assert(math.type(major) == "integer" and math.type(minor) == "integer",
			"both components are integers")
		assert(major >= 0 and minor >= 0, "both components non-negative")
		_G.__major, _G.__minor = major, minor
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
		return
	}
	// The Lua-observed pair must BE the Odin build-time constants (the same
	// pair `makac --version` prints).
	lua.getglobal(v.state, "__major")
	major := lua.tointeger(v.state, -1)
	lua.pop(v.state, 1)
	lua.getglobal(v.state, "__minor")
	minor := lua.tointeger(v.state, -1)
	lua.pop(v.state, 1)
	testing.expect_value(t, int(major), VERSION_MAJOR)
	testing.expect_value(t, int(minor), VERSION_MINOR)
}

@(test)
test_env_makac_path :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local p = makac.env.makac_path()
		assert(type(p) == "userdata", "makac_path returns a path value")
		local s = tostring(p)
		assert(s:sub(1, 1) == "/", "must be absolute: " .. s)
		assert(makac.fs.stat(s) ~= nil, "must exist on disk: " .. s)
		_G.__mpath = s
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
		return
	}
	// Cross-check against the Odin-side answer for THIS test process.
	lua.getglobal(v.state, "__mpath")
	s := runtime.cstring_to_string(lua.tostring(v.state, -1))
	lua.pop(v.state, 1)
	expected, gerr := os.get_executable_path(context.temp_allocator)
	testing.expect(t, gerr == nil, "get_executable_path failed")
	testing.expect(t, strings.compare(s, expected) == 0, "Lua and Odin must agree")
}
