// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
package vm

import "core:testing"

// makac.fs — the `path` type (design2/stdlib.md, "makac.fs — paths"):
// constructor cleaning, join/drop-empty, dirname/basename edge cases,
// method vs free function equivalence, string-or-path coercion on every
// path-taking fs function.

@(test)
test_path_constructor_cleans :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local p = makac.fs.path("/a//b/./c")
		assert(tostring(p) == "/a/b/c", "ctor cleans its argument")
		-- path(path) round-trips cleaned
		assert(tostring(makac.fs.path(p)) == "/a/b/c")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_path_join_drops_empty :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local p = makac.fs.path_join("/a", "", "b", "")
		assert(tostring(p) == "/a/b", "path_join drops empty elements")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_path_dirname_basename_edges :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- trailing slash cleans away, then dir/base act on the clean path
		local p = makac.fs.path("/a/b/")
		assert(tostring(p:dirname()) == "/a", "trailing-slash dirname")
		assert(p:basename() == "b", "trailing-slash basename")
		-- root: basename is core:os's base result (empty file part)
		local r = makac.fs.path("/")
		assert(r:basename() == "", "basename of root")
		assert(tostring(r:dirname()) == "/", "dirname of root")
		-- bare element: core:os's dir returns "" (spec: verbatim core call)
		local q = makac.fs.path("c")
		assert(q:basename() == "c", "bare element's basename")
		assert(tostring(q:dirname()) == "", "bare element's dirname")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_path_method_matches_free_function :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local p = makac.fs.path("/a/b")
		local m = p:join("c", "d")
		local f = makac.fs.path_join(p, "c", "d")
		assert(tostring(m) == "/a/b/c/d", "method join result")
		assert(tostring(f) == "/a/b/c/d", "free fn join result")
		assert(tostring(m) == tostring(f), "method == free fn")
		-- string elements coerce identically both ways
		local g = makac.fs.path_join(p, "e")
		assert(tostring(g) == "/a/b/e")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_path_coercion_in_fs_calls :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local dir = makac.fs.mktemp_dir()
		local dirstr = tostring(dir)
		-- fs.stat accepts path AND string equivalently
		assert(makac.fs.stat(dir) ~= nil and makac.fs.stat(dir).type == "dir")
		assert(makac.fs.stat(dirstr) ~= nil and makac.fs.stat(dirstr).type == "dir")
		-- write_file + read_file both coerce
		local f = makac.fs.path_join(dir, "nx.txt")
		makac.fs.write_file(f, "hello")
		local data, rerr = makac.fs.read_file(f)
		assert(data == "hello", "read back through the path object")
		local fstr = tostring(f)
		local data2 = makac.fs.read_file(fstr)
		assert(data2 == "hello", "read back through the string")
		-- mkdir_p / listdir take paths as well
		local sub = makac.fs.path_join(dir, "sub")
		makac.fs.mkdir_p(sub)
		local entries = makac.fs.listdir(dir)
		assert(type(entries) == "table", "listdir on path")
		os.remove(dirstr)
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}

@(test)
test_path_null_file_and_step_constants :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local nf = makac.fs.null_file()
		assert(tostring(nf) == "/dev/null", "null_file is /dev/null")
		assert(makac.fs.sep == "/", "sep constant")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok) {
		log_time_err(t, err)
	}
}
