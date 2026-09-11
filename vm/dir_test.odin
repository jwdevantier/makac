// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
package vm

import "core:os"
import "core:strings"
import "core:testing"

// makac.fs — directory handles (Dir) (design2/stdlib.md). Fixture tree per
// test (built Odin-side, asserted Lua-side through the VM):
//   <root>/a/           dir
//   <root>/a/b/         dir      (empty)
//   <root>/a/x.txt      file
//   <root>/a/b/y.txt    file
//   <root>/README.md    file

@(private = "file")
_dir_fixture :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "makac_dir_fixture_*", context.allocator)
	if !testing.expect(t, err == nil, "temp dir") {return ""}
	merr := os.make_directory_all(
		strings.concatenate({dir, "/a/b"}, context.temp_allocator),
	)
	if !testing.expect(t, merr == nil, "fixture dirs") {
		os.remove_all(dir)
		return ""
	}
	paths := []string{"/a/x.txt", "/a/b/y.txt", "/README.md"}
	for p in paths {
		werr := os.write_entire_file_from_string(
			strings.concatenate({dir, p}, context.temp_allocator),
			"fixture",
		)
		if !testing.expect(t, werr == nil, "fixture file") {
			os.remove_all(dir)
			return ""
		}
	}
	return dir
}

// Shape: fs.cwd/fs.open_dir exist; the Dir carries the Dir method set.
@(test)
test_dir_shape :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.fs.cwd) == "function", "cwd must be a function")
		assert(type(makac.fs.open_dir) == "function", "open_dir must be a function")
		local d = makac.fs.cwd()
		assert(type(d) == "userdata", "cwd() returns a Dir userdata")
		for _, m in ipairs({"path", "exists", "touch", "make_path", "open_dir",
				"parent", "list", "walk", "remove"}) do
			assert(type(d[m]) == "function", "Dir method missing: " .. m)
		end
		local s = tostring(d)
		assert(s:sub(1, 1) == "/", "cwd Dir tostring is absolute: " .. s)
		`,
		"@dir_shape.lua",
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

@(test)
test_dir_open_dir_construction_failures :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local ok1, e1 = pcall(makac.fs.open_dir, "`,
			root,
			`/missing")
assert(not ok1, "open_dir on a missing path must raise")
local ok2, e2 = pcall(makac.fs.open_dir, "`,
			root,
			`/README.md")
assert(not ok2, "open_dir on a file must raise")
-- a string and a path value both work
local d1 = makac.fs.open_dir("`,
			root,
			`")
local d2 = makac.fs.open_dir(d1:path())
assert(tostring(d1:path()) == "`,
			root,
			`", "root canonicalized (absolute+clean)")
assert(tostring(d2:path()) == "`,
			root,
			`", "path-arg construction works")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_open_dir_construction_failures")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// Sub validation: absolute and '..' violate (raise), on every operation.
@(test)
test_dir_sub_validation :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
for _, call in ipairs({
	function() return d:exists("/abs") end,
	function() d:touch("/abs") end,
	function() d:make_path("/abs") end,
	function() return d:open_dir("/abs") end,
	function() d:remove("/abs") end,
	function() return d:exists("a/../b") end,
	function() return d:exists("..") end,
}) do
	local ok = pcall(call)
	assert(not ok, "violation must raise")
end
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_sub_validation")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// exists/touch/make_path/open_dir/parent round-trips.
@(test)
test_dir_method_roundtrips :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
assert(d:exists(), "root exists (sub omitted)")
assert(d:exists("a"), "dir a exists")
assert(not d:exists("nope"), "absence is a plain false")
d:touch("newfile")
assert(d:exists("newfile"), "touch creates")
d:make_path("c/d")
assert(d:exists("c/d"), "make_path nests")
local sub = d:open_dir("a/b")
assert(tostring(sub:path()) == "`,
			root,
			`/a/b", "descend joins")
local par = sub:parent()
assert(tostring(par:path()) == "`,
			root,
			`/a", "parent navigates")
assert(sub:exists("y.txt"), "subdir handle operates on its own root")
-- path() returns a path value
assert(type(d:path()) == "userdata", "path() is a path value")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_method_roundtrips")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// list entry shape: name + type, stat vocabulary.
@(test)
test_dir_list_shape :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
local entries = d:list()
assert(type(entries) == "table", "list returns a table")
assert(#entries == 2, "one level only, got " .. #entries)
local by_name = {}
for _, e in ipairs(entries) do
	assert(type(e.name) == "string" and type(e.type) == "string",
		"entry shape name+type")
	by_name[e.name] = e.type
end
assert(by_name["a"] == "dir", "a is a dir")
assert(by_name["README.md"] == "file", "README is a file")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_list_shape")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// walk: depth-first, directories before their contents; (sub, type) pairs;
// exact membership, once each.
@(test)
test_dir_walk_order_and_membership :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
local want = {
	["a"] = "dir", ["a/b"] = "dir", ["a/x.txt"] = "file",
	["a/b/y.txt"] = "file", ["README.md"] = "file",
}
local seen = {}
local pos = {}
local n = 0
for subp, kind in d:walk() do
	n = n + 1
	assert(want[subp] == kind, "unexpected entry: " .. subp .. " (" .. kind .. ")")
	assert(seen[subp] == nil, "entry yielded twice: " .. subp)
	seen[subp] = true
	pos[subp] = n
end
assert(n == 5, "all entries yielded, got " .. n)
-- directories before their contents (structural; readdir order within a
-- directory is unspecified, membership+kind above is exact)
for subp in pairs(seen) do
	if want[subp] == "dir" then
		for other in pairs(seen) do
			if other:sub(1, #subp + 1) == subp .. "/" then
				assert(pos[subp] < pos[other],
					"dir " .. subp .. " yielded after " .. other)
			end
		end
	end
end
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_walk_order_and_membership")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// remove: recursive on directories, root-remove when sub omitted, and the
// stale-handle reporting (exists() -> false; queries that can answer do).
@(test)
test_dir_remove_semantics :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
d:remove("a")
assert(not d:exists("a"), "recursive remove works")
assert(d:exists(), "root survives subtree removal")
d:remove()
assert(not d:exists(), "root-remove (sub omitted)")
-- removing an absent target raises
local ok = pcall(function() d:remove("a") end)
assert(not ok, "remove of absent target raises")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_remove_semantics")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}

// List/walk on a stale handle raise (only exists reports absence as data).
@(test)
test_dir_stale_handle_raises_for_queries :: proc(t: ^testing.T) {
	root := _dir_fixture(t)
	defer os.remove_all(root)
	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local d = makac.fs.open_dir("`,
			root,
			`")
d:remove()
local ok1 = pcall(function() return d:list() end)
assert(not ok1, "list on stale root raises")
local ok2 = pcall(function() for _ in d:walk() do end end)
assert(not ok2, "walk on stale root raises")
-- a missing arg where one is required raises too
local ok3 = pcall(function() d:touch() end)
assert(not ok3, "touch without sub raises")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_dir_stale_handle_raises_for_queries")
	if !ok {defer delete(err.message)}
	testing.expect(t, ok, "lua asserts must pass")
}
