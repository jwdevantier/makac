// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

import lua "vendor:lua/5.4"

// makac.json (design/stdlib.md) — dumps/loads over the shared Lua↔JSON
// converters below. Those converters were written for the qmp binding
// (qmp:send marshals command arguments with exactly these rules); they live
// here so qmp and json.dumps/json.loads can never drift apart:
//
//   tables are JSON objects unless every key is an integer in 1..n (then
//   arrays); an empty table encodes as {}; functions/userdata/mixed-key
//   tables raise with the value's path in the message; decoding keeps
//   integers as integers (json.parse_string with parse_integers=true).

// The Lua type name of the value at `idx` ("function", "userdata", ...).
// NB: lua.L_typename is a macro reimplemented by the binding as
// typename(L, type(L, idx)) — passing a TYPE code straight into type()
// would index the stack at that number and yield "no value".
@(private = "file")
_type_name_at :: proc "c" (L: ^lua.State, idx: c.int) -> cstring {
	return lua.typename(L, lua.type(L, idx))
}

// Convert the Lua value at `idx` to a JSON value tree (temp allocator).
// Tables: an array iff every key is an integer in 1..n; an empty table is an
// OBJECT (so `arguments = {}` marshals to `{}`); mixed-key tables and
// non-JSON-able values raise. `path` locates the value in error messages
// (e.g. "commands[2].arguments.driver"), `prefix` names the caller-facing
// API in them (e.g. "makac.qmp" / "makac.json").
_lua_to_json :: proc "c" (L: ^lua.State, idx: c.int, path: string, prefix: cstring) -> json.Value {
	context = runtime.default_context()
	abs := lua.absindex(L, idx)
	#partial switch lua.Type(lua.type(L, abs)) {
	case .NIL:
		return json.Null(nil)
	case .BOOLEAN:
		return json.Boolean(bool(lua.toboolean(L, abs)))
	case .NUMBER:
		if lua.isinteger(L, abs) {
			return json.Integer(i64(lua.tointeger(L, abs)))
		}
		return json.Float(f64(lua.tonumber(L, abs)))
	case .STRING:
		l: c.size_t
		s := lua.tolstring(L, abs, &l)
		return json.String(strings.clone(_cstr(s, l), context.temp_allocator))
	case .TABLE:
		n := int(lua.rawlen(L, abs))
		count := 0
		is_arr := n > 0
		lua.pushnil(L)
		for lua.next(L, abs) != 0 {
			count += 1
			if lua.Type(lua.type(L, -2)) != .NUMBER || !lua.isinteger(L, -2) {
				is_arr = false
			}
			lua.pop(L, 1)
		}
		if is_arr && count == n {
			arr := make(json.Array, 0, n, context.temp_allocator)
			for i in 1 ..= n {
				lua.rawgeti(L, abs, lua.Integer(i))
				append(&arr, _lua_to_json(L, -1, fmt.tprintf("%s[%d]", path, i), prefix))
				lua.pop(L, 1)
			}
			return arr
		}
		if is_arr {
			lua.L_error(
				L,
				"%s: %s mixes array and non-array keys; cannot encode as JSON",
				prefix,
				cstring(raw_data(path)),
			)
			return nil
		}
		obj := make(json.Object, allocator = context.temp_allocator)
		lua.pushnil(L)
		for lua.next(L, abs) != 0 {
			// key at -2, value at -1
			if lua.Type(lua.type(L, -2)) != .STRING {
				lua.L_error(
					L,
					"%s: %s: JSON object keys must be strings, got %s",
					prefix,
					cstring(raw_data(path)),
					_type_name_at(L, -2),
				)
				return nil
			}
			kl: c.size_t
			ks := lua.tolstring(L, -2, &kl)
			key := strings.clone(_cstr(ks, kl), context.temp_allocator)
			obj[key] = _lua_to_json(L, -1, fmt.tprintf("%s.%s", path, key), prefix)
			lua.pop(L, 1)
		}
		return obj
	case:
		lua.L_error(
			L,
			"%s: %s: %s values cannot be encoded as JSON",
			prefix,
			cstring(raw_data(path)),
			_type_name_at(L, abs),
		)
	}
	return nil
}

// Push a parsed JSON value onto the Lua stack as plain Lua values
// (objects/arrays become tables; integers stay integers).
_push_json :: proc "c" (L: ^lua.State, v: json.Value) {
	context = runtime.default_context()
	switch x in v {
	case json.Null:
		lua.pushnil(L)
	case json.Boolean:
		lua.pushboolean(L, b32(x))
	case json.Integer:
		lua.pushinteger(L, lua.Integer(x))
	case json.Float:
		lua.pushnumber(L, lua.Number(x))
	case json.String:
		_push_lstring(L, x)
	case json.Array:
		lua.createtable(L, c.int(len(x)), 0)
		for elem, i in x {
			_push_json(L, elem)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.createtable(L, 0, c.int(len(x)))
		for key, val in x {
			_push_json(L, val)
			lua.setfield(L, -2, strings.clone_to_cstring(key, context.temp_allocator))
		}
	}
}

// Submodule table plumbing — mirrors vm/time.odin: the `register` helper
// only adds flat makac.* entries, so submodules resolve their own table.

// Pushes the makac.json submodule table onto the stack (shared plumbing:
// register.odin's _push_submodule).
@(private = "file")
_push_json_submodule :: proc(v: ^VM) {
	_push_submodule(v, "json")
}

register_json_primitives :: proc(v: ^VM) {
	L := v.state
	_push_json_submodule(v)
	defer lua.pop(L, 1)
	lua.pushcclosure(L, _makac_json_dumps, 0)
	lua.setfield(L, -2, "dumps")
	lua.pushcclosure(L, _makac_json_loads, 0)
	lua.setfield(L, -2, "loads")
}

// makac.json.dumps(value) -> string — raises on unencodable values.
@(private = "file")
_makac_json_dumps :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	lua.L_checkany(L, 1)
	value := _lua_to_json(L, 1, "value", "makac.json")
	data, merr := json.marshal(json.Value(value), {}, context.temp_allocator)
	if merr != nil {
		return c.int(lua.L_error(L, "makac.json: dumps: failed to encode value as JSON"))
	}
	_push_lstring(L, string(data))
	return 1
}

// makac.json.loads(string) -> value — raises on malformed JSON.
@(private = "file")
_makac_json_loads :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	// Strict: lua.L_checkstring would happily COERCE a number argument to
	// its string form; loads(42) must raise instead.
	lua.L_checktype(L, 1, c.int(lua.Type.STRING))
	l: c.size_t
	s := lua.tolstring(L, 1, &l)
	src := _cstr(s, l)
	value, perr := json.parse_string(
		src,
		json.Specification.JSON,
		true, // parse_integers: decoding keeps integers as integers
		context.temp_allocator,
	)
	if perr != nil {
		return c.int(
			lua.L_error(
				L,
				"makac.json: loads: malformed JSON: %s",
				strings.clone_to_cstring(src, context.temp_allocator),
			),
		)
	}
	_push_json(L, value)
	return 1
}
