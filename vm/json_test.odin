// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:testing"

// makac.json — dumps/loads (design/stdlib.md). Same converters as qmp:send.

// makac.json is a table with the two functions.
@(test)
test_json_shape :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.json) == "table", "makac.json must be a table")
		assert(type(makac.json.dumps) == "function", "dumps must be a function")
		assert(type(makac.json.loads) == "function", "loads must be a function")
		`,
		"@json_shape.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Round-trip a nested table: objects, arrays, scalars of every JSON type.
@(test)
test_json_roundtrip_nested :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local orig = {
			name = "vm1",
			cpus = 4,
			mem_mib = 4096,
			pi = 3.5,
			enabled = true,
			disabled = false,
			nothing = nil,  -- nil fields vanish (Lua table semantics)
			nested = { drives = { "nvme0", "sda" }, flags = { true, false } },
			list = { 1, "two", 3.25, { deep = "x" } },
		}
		local s = makac.json.dumps(orig)
		assert(type(s) == "string", "dumps must return a string")
		local back = makac.json.loads(s)
		assert(back.name == "vm1", "name round-trips")
		assert(back.cpus == 4 and math.type(back.cpus) == "integer", "cpus round-trips as integer")
		assert(back.mem_mib == 4096, "mem_mib round-trips")
		assert(back.pi == 3.5, "float round-trips")
		assert(back.enabled == true and back.disabled == false, "booleans round-trip")
		assert(back.nested.drives[1] == "nvme0" and back.nested.drives[2] == "sda", "nested array round-trips")
		assert(back.nested.flags[1] == true and back.nested.flags[2] == false, "nested flags round-trip")
		assert(back.list[1] == 1 and back.list[2] == "two" and back.list[3] == 3.25, "mixed array round-trips")
		assert(back.list[4].deep == "x", "table inside array round-trips")
		assert(back.nothing == nil, "nil stays absent")
		-- key ORDER is not stable (both the encoder and the decoder iterate
		-- hash maps); only the structure is.
		`,
		"@json_roundtrip.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// An empty table encodes as a JSON object {} (the `arguments = {}` rule).
@(test)
test_json_empty_table_is_object :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(makac.json.dumps({}) == "{}", "empty table must encode as {}")
		assert(makac.json.dumps({ empty = {} }) == '{"empty":{}}', "nested empty table too")
		local back = makac.json.loads("{}")
		assert(type(back) == "table" and next(back) == nil, "{} decodes to an empty table")
		local arr = makac.json.loads("[]")
		assert(type(arr) == "table" and #arr == 0, "[] decodes to an empty array table")
		`,
		"@json_empty.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Integers decode as integers (and floats as floats).
@(test)
test_json_integer_preservation :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local v = makac.json.loads('{"a": 1, "b": -42, "big": 4611686018427387903, "f": 2.5, "e": 1e3}')
		assert(math.type(v.a) == "integer" and v.a == 1, "a is integer")
		assert(math.type(v.b) == "integer" and v.b == -42, "b is integer")
		assert(math.type(v.big) == "integer" and v.big == 4611686018427387903, "big is integer")
		assert(math.type(v.f) == "float" and v.f == 2.5, "f is float")
		assert(math.type(v.e) == "float" and v.e == 1000.0, "e is float")
		assert(makac.json.dumps(7) == "7", "integer scalar dumps")
		-- core:encoding/json renders floats with %f precision (2.5 ->
		-- "2.5000000000000000"); equality of the NUMBER matters, not text.
		assert(makac.json.loads(makac.json.dumps(2.5)) == 2.5, "float scalar round-trips")
		assert(makac.json.loads(makac.json.dumps(1e3)) == 1000.0, "1e3 round-trips")
		`,
		"@json_integers.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Arrays/objects by key shape: contiguous integer keys are arrays; anything
// else is an object or raises.
@(test)
test_json_array_vs_object_keys :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(makac.json.dumps({1, 2, 3}) == "[1,2,3]", "array keys encode as array")
		assert(makac.json.dumps({ "a", { "b", "c" } }) == '["a",["b","c"]]', "nested arrays")
		assert(makac.json.dumps({ x = 1 }) == '{"x":1}', "string keys encode as object")
		-- sparse / non-1-based integer keys are object-shaped but integer
		-- keys are not strings: must raise
		local ok1, e1 = pcall(makac.json.dumps, { [2] = "a", [3] = "b" })
		assert(not ok1, "non-1..n integer keys must raise")
		assert(e1:find("makac%.json"), "error names makac.json")
		-- mixed keys raise (an integer key reached in the object pass trips
		-- the string-key rule; the message names the offending key type)
		local ok2, e2 = pcall(makac.json.dumps, { 1, 2, extra = true })
		assert(not ok2, "mixed array+hash keys must raise")
		assert(e2:find("number") or e2:find("mixes"), "error names the problem, got: " .. tostring(e2))
		`,
		"@json_keyshape.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Functions, userdata and nested-uncodable values raise with the value's
// path in the message.
@(test)
test_json_raises_on_uncodable :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local ok1, e1 = pcall(makac.json.dumps, function() end)
		assert(not ok1, "top-level function must raise")
		assert(e1:find("function"), "error names the offending type")
		local ok2, e2 = pcall(makac.json.dumps, { cb = function() end })
		assert(not ok2, "nested function must raise")
		assert(e2:find("value%.cb"), "error carries the path (value.cb), got: " .. tostring(e2))
		local ok3, e3 = pcall(makac.json.dumps, { list = { 1, print } })
		assert(not ok3, "function inside array must raise")
		assert(e3:find("value%.list%[2%]"), "error carries the path (value.list[2]), got: " .. tostring(e3))
		`,
		"@json_uncodable.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Malformed JSON raises (errors-raise convention).
@(test)
test_json_loads_malformed_raises :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local ok1, e1 = pcall(makac.json.loads, "{ not json")
		assert(not ok1, "truncated object must raise")
		assert(e1:find("malformed"), "error says malformed")
		local ok2 = pcall(makac.json.loads, "[1, 2,")
		assert(not ok2, "truncated array must raise")
		local ok3 = pcall(makac.json.loads, "")
		assert(not ok3, "empty input must raise")
		local ok4 = pcall(makac.json.loads, "{x: 1}")
		assert(not ok4, "unquoted key must raise")
		local ok5 = pcall(makac.json.loads, 42)
		assert(not ok5, "non-string arg must raise")
		-- scalar values decode fine
		assert(makac.json.loads("null") == nil, "null decodes to nil")
		assert(makac.json.loads("true") == true, "true decodes")
		assert(makac.json.loads('"hi"') == "hi", "string decodes")
		`,
		"@json_malformed.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Depth/cycle guards: a cyclic table must raise a Lua error naming the
// limit, not grow the C stack until the process dies; a DAG (shared
// subtrees) is NOT a cycle and must keep working; the decode direction is
// bounded the same way, with the exact boundary pinned.
@(test)
test_json_depth_and_cycle_guards :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- cyclic table: must raise, naming the limit
		local cyc = {}; cyc.self = cyc
		local ok1, e1 = pcall(makac.json.dumps, cyc)
		assert(not ok1, "dumps of a cyclic table must raise")
		assert(tostring(e1):find("nesting exceeds"), tostring(e1))

		-- deep but ACYCLIC: same guard, same error
		local deep = {}
		for _ = 1, 100 do deep = { next = deep } end
		local ok2, e2 = pcall(makac.json.dumps, deep)
		assert(not ok2 and tostring(e2):find("nesting exceeds"), tostring(e2))

		-- shared subtrees (a DAG): NOT a cycle — must round-trip
		local shared = { x = 1 }
		local dag = { a = shared, b = shared }
		local rt = makac.json.loads(makac.json.dumps(dag))
		assert(rt.a.x == 1 and rt.b.x == 1, "shared subtrees must encode")

		-- decode: past the bound raises (the string parses; the push
		-- recursion is what is bounded), at the bound still works
		local over = ("["):rep(80) .. ("]"):rep(80)
		local ok3, e3 = pcall(makac.json.loads, over)
		assert(not ok3 and tostring(e3):find("nesting exceeds"), tostring(e3))
		local ok4 = pcall(makac.json.loads, ("["):rep(65) .. ("]"):rep(65))
		assert(not ok4, "65 levels must raise")
		local ok5 = pcall(makac.json.loads, ("["):rep(64) .. ("]"):rep(64))
		assert(ok5, "64 levels must decode")
		`,
		"@json_depth.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}
