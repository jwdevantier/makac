// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:strings"

import lua "vendor:lua/5.4"

// register adds `fn` to the global Lua table `makac` under `name`, creating
// the table if it does not exist yet. All Odin-side primitives exposed to
// Lua go through this so that user scripts always find them at makac.<name>.
register :: proc(v: ^VM, name: string, fn: lua.CFunction) {
	L := v.state
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if lua.Type(lua.getglobal(L, "makac")) != .TABLE {
		lua.pop(L, 1)
		lua.createtable(L, 0, 8)
		lua.pushvalue(L, -1)
		lua.setglobal(L, "makac")
	}
	lua.pushcclosure(L, fn, 0)
	lua.setfield(L, -2, cname)
	lua.pop(L, 1)
}

// _push_submodule pushes the makac.<name> submodule table onto the stack,
// creating and registering it as field `name` of the global `makac` table
// when absent. Submodule areas (fs/time/json/env) resolve their table this
// way; there is exactly ONE table per name no matter how many registration
// passes add fields to it. Caller pops.
_push_submodule :: proc(v: ^VM, name: string) {
	L := v.state
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if lua.Type(lua.getglobal(L, "makac")) != .TABLE {
		lua.pop(L, 1)
		lua.createtable(L, 0, 8)
		lua.pushvalue(L, -1)
		lua.setglobal(L, "makac")
	}
	if lua.Type(lua.getfield(L, -1, cname)) == .TABLE {
		lua.remove(L, -2) // keep submodule, drop makac
		return
	}
	lua.pop(L, 1) // the non-table field
	lua.createtable(L, 0, 8)
	lua.pushvalue(L, -1)
	lua.setfield(L, -3, cname)
	lua.remove(L, -2) // keep submodule, drop makac
}
