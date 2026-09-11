// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sys/posix"

import lua "vendor:lua/5.4"

// makac.time — the poll-loop primitives Lua lacks (design2/stdlib.md).
// One unit everywhere: integer nanoseconds. `now` is CLOCK_MONOTONIC (never
// wall time) so "deadline = now() + timeout * ns_per_s" arithmetic is safe
// across NTP jumps; `sleep` is nanosleep with EINTR resume.
//
// The submodule is a plain table set as field `time` of the global `makac`
// table (the `register` helper only adds flat makac.* entries, so this file
// resolves the table itself).

// Upper bound for sleep: 10 years in nanoseconds. Larger requests are a bug
// in the caller (unit confusion), not a legitimate wait — raise.
_MAX_SLEEP_NS :: i64(10) * 365 * 24 * 60 * 60 * 1_000_000_000

// Pushes the makac.time submodule table onto the stack (shared plumbing:
// register.odin's _push_submodule).
_push_time_submodule :: proc(v: ^VM) {
	_push_submodule(v, "time")
}

_register_time_fn :: proc(v: ^VM, name: string, fn: lua.CFunction) {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	lua.pushcclosure(v.state, fn, 0)
	lua.setfield(v.state, -2, cname)
}

_register_time_int :: proc(v: ^VM, name: string, value: i64) {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	lua.pushinteger(v.state, lua.Integer(value))
	lua.setfield(v.state, -2, cname)
}

register_time_primitives :: proc(v: ^VM) {
	_push_time_submodule(v)
	defer lua.pop(v.state, 1)
	_register_time_fn(v, "sleep", _makac_time_sleep)
	_register_time_fn(v, "now", _makac_time_now)
	_register_time_int(v, "ns_per_us", 1_000)
	_register_time_int(v, "ns_per_ms", 1_000_000)
	_register_time_int(v, "ns_per_s", 1_000_000_000)
}

// makac.time.sleep(ns) — suspend for ns nanoseconds; resumes on EINTR.
// No return values. ns must be a non-negative integer within a sane bound;
// anything else raises (bad arguments are errors, design2/stdlib.md).
_makac_time_sleep :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	ns := i64(lua.L_checkinteger(L, 1))
	if ns < 0 {
		return c.int(lua.L_error(L, "makac.time.sleep: ns must not be negative"))
	}
	if ns > _MAX_SLEEP_NS {
		return c.int(lua.L_error(L, "makac.time.sleep: ns is absurdly large (max 10 years)"))
	}
	req := posix.timespec{
		tv_sec  = posix.time_t(ns / 1_000_000_000),
		tv_nsec = c.long(ns % 1_000_000_000),
	}
	rem: posix.timespec
	for posix.nanosleep(&req, &rem) != .OK {
		if posix.errno() == .EINTR {
			req = rem
			continue
		}
		return c.int(lua.L_error(L, "makac.time.sleep: nanosleep failed"))
	}
	return 0
}

// makac.time.now() -> integer — CLOCK_MONOTONIC in nanoseconds.
_makac_time_now :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	ts: posix.timespec
	if posix.clock_gettime(.MONOTONIC, &ts) != .OK {
		return c.int(lua.L_error(L, "makac.time.now: clock_gettime(CLOCK_MONOTONIC) failed"))
	}
	ns := i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
	lua.pushinteger(L, lua.Integer(ns))
	return 1
}
