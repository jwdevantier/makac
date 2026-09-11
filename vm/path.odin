// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

// makac.fs — the `path` type (design2/stdlib.md, "makac.fs — paths"). A
// userdata with metatable "makac.path" holding ONE cleaned path string;
// same object discipline as "makac.ssh"/"makac.qmp": no resources to close,
// trivial __gc (frees raw by stored allocator — see newuserdata struct
// note in register_... primitives).
//
//   makac.fs.path(s) -> path                     -- s: string or path
//   makac.fs.path_join(a, b, ...) -> path        -- variadic; "" dropped
//   makac.fs.null_file() -> path                 -- "/dev/null"
//   makac.fs.sep                                 -- constant "/"
//
//   tostring(p)    -> string   -- THE escape hatch
//   p:dirname()    -> path     -- "/a/b/c" -> "/a/b"
//   p:basename()   -> string   -- "/a/b/c" -> "c"
//   p:join(x, ...) -> path     -- == fs.path_join(p, x, ...)
//
// Implementations are one call each into core:path/filepath
// (clean/join/dir/base). Deliberately minimal: NO ext/absolute/clean
// methods.

PATH_MT :: "makac.path"

Path_Value :: struct {
	raw: string, // owned (context.allocator), freed by __gc
}

// register_path_on_fs — called by fs.odin's register_fs_primitives while
// the `makac.fs` submodule table sits at top of stack. Creates the
// "makac.path" metatable and sets path/path_join/null_file/sep on it.
register_path_on_fs :: proc "c" (L: ^lua.State) {
	context = runtime.default_context()
	if lua.L_newmetatable(L, PATH_MT) != 0 {
		lua.pushcclosure(L, _path_index, 0)
		lua.setfield(L, -2, "__index")
		lua.pushcclosure(L, _path_gc, 0)
		lua.setfield(L, -2, "__gc")
		lua.pushcclosure(L, _path_tostring, 0)
		lua.setfield(L, -2, "__tostring")
	}
	lua.pop(L, 1)

	// fs table must be at index -1 again after popping the metatable.
	lua.pushcclosure(L, _makac_fs_path, 0)
	lua.setfield(L, -2, "path")
	lua.pushcclosure(L, _makac_fs_path_join, 0)
	lua.setfield(L, -2, "path_join")
	lua.pushcclosure(L, _makac_fs_null_file, 0)
	lua.setfield(L, -2, "null_file")
	lua.pushstring(L, "/")
	lua.setfield(L, -2, "sep")
}

// check_path_string — the coercion helper for every fs function that takes
// a string-or-path argument: STRING returns a stack-anchored view,
// USERDATA of metatable PATH_MT returns its raw; anything else raises.
check_path_string :: proc "c" (L: ^lua.State, idx: c.int) -> string {
	context = runtime.default_context()
	#partial switch lua.Type(lua.type(L, idx)) {
	case .STRING:
		return runtime.cstring_to_string(lua.tostring(L, idx))
	case .USERDATA:
		ud := lua.L_testudata(L, idx, PATH_MT)
		if ud != nil {
			return (^Path_Value)(ud).raw
		}
	}
	lua.L_error(
		L,
		"string or path expected (#%d) (got %s)",
		idx,
		lua.L_typename(L, c.int(lua.type(L, idx))),
	)
	return ""
}

// _push_path — wrap `raw` in a "makac.path" userdata on top of the stack,
// cloning it with context.allocator so __gc owns it.
_push_path :: proc "c" (L: ^lua.State, raw: string) {
	context = runtime.default_context()
	ud := (^Path_Value)(lua.newuserdata(L, c.size_t(size_of(Path_Value))))
	ud^ = Path_Value {
		raw = strings.clone(raw, context.allocator),
	}
	lua.L_setmetatable(L, PATH_MT)
}

// __index: method dispatch (dirname, basename, join).
@(private = "file")
_path_index :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if lua.Type(lua.type(L, 2)) != .STRING {
		lua.pushnil(L)
		return 1
	}
	switch runtime.cstring_to_string(lua.tostring(L, 2)) {
	case "dirname":  lua.pushcclosure(L, _path_dirname, 0)
	case "basename": lua.pushcclosure(L, _path_basename, 0)
	case "join":     lua.pushcclosure(L, _path_join_method, 0)
	case:            lua.pushnil(L)
	}
	return 1
}

// __gc: free raw. Never raises.
@(private = "file")
_path_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Path_Value)(lua.L_checkudata(L, 1, PATH_MT))
	if self.raw != "" {delete(self.raw, context.allocator)}
	self^ = {}
	return 0
}

@(private = "file")
_path_tostring :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Path_Value)(lua.L_checkudata(L, 1, PATH_MT))
	lua.pushlstring(L, cstring(raw_data(self.raw)), c.size_t(len(self.raw)))
	return 1
}

// makac.fs.path(s) — cleaned argument wrapped. Cleans with
// context.allocator so the userdata takes ownership without a second
// clone.
@(private = "file")
_makac_fs_path :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	s := check_path_string(L, 1)
	cleaned, cerr := filepath.clean(s, context.allocator)
	if cerr != nil {
		return c.int(lua.L_error(L, "makac.fs: path: clean failed"))
	}
	ud := (^Path_Value)(lua.newuserdata(L, c.size_t(size_of(Path_Value))))
	ud^ = Path_Value{raw = cleaned}
	lua.L_setmetatable(L, PATH_MT)
	return 1
}

// Shared join core: join whatever string-or-path args sit at indices
// from..top, dropping "" elements (spec; both for path_join and
// p:join(...)). Uses temp_allocator scratch; result is cloned into the
// pushed path value via _push_path.
@(private = "file")
_join_args_push :: proc "c" (L: ^lua.State, from: c.int) -> c.int {
	argc := lua.gettop(L)
	context = runtime.default_context()
	elems := make([dynamic]string, context.temp_allocator)
	for i in from ..= argc {
		e := check_path_string(L, i)
		if e != "" {
			append(&elems, e)
		}
	}
	if len(elems) == 0 {
		_push_path(L, "")
		return 1
	}
	joined, jerr := filepath.join(elems[:], context.temp_allocator)
	if jerr != nil {
		return c.int(lua.L_error(L, "make join failed: %v", jerr))
	}
	_push_path(L, joined)
	return 1
}

// makac.fs.path_join(a, b, ...) — variadic; empty elements dropped.
@(private = "file")
_makac_fs_path_join :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _join_args_push(L, 1)
}

// p:join(x, ...) — == fs.path_join(p, x, ...) — self is arg 1; from := 1.
@(private = "file")
_path_join_method :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return _join_args_push(L, 1)
}

// makac.fs.null_file() — "/dev/null" (spawn's stdin default).
@(private = "file")
_makac_fs_null_file :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	_push_path(L, "/dev/null")
	return 1
}

// p:dirname() — "/a/b/c" -> "/a/b" (core:path/filepath's dir).
@(private = "file")
_path_dirname :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Path_Value)(lua.L_checkudata(L, 1, PATH_MT))
	_push_path(L, filepath.dir(self.raw))
	return 1
}

// p:basename() — "/a/b/c" -> "c" (string, not path).
@(private = "file")
_path_basename :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	self := (^Path_Value)(lua.L_checkudata(L, 1, PATH_MT))
	base := filepath.base(self.raw)
	lua.pushlstring(L, cstring(raw_data(base)), c.size_t(len(base)))
	return 1
}
