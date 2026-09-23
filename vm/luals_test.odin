// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:os"
import "core:strings"
import "core:testing"

// makac.luals_setup (design/luacats.md) writes the embedded base stub into the
// data dir and one <data>/pkgs/<id> alias per package DEFINITION (so it works
// right after `makac fetch`, without loading packages), and points the
// project .luarc.json's workspace.library at the data dir as the single root.
@(test)
test_luals_setup_installs_stub_and_alias :: proc(t: ^testing.T) {
	root, rerr := os.make_directory_temp("", "makac_luals_*", context.allocator)
	testing.expect(t, rerr == nil, "temp dir")
	defer delete(root)
	defer os.remove_all(root)
	data := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{data, "/packages/demo/lib"}, context.temp_allocator),
		) ==
		nil,
		"package lib dir",
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{data, "/packages/demo/lib/util.lua"}, context.temp_allocator),
			"lib-marker\n",
		) ==
		nil,
		"package lib file",
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{data, "/packages.lua"}, context.temp_allocator),
			`return { { id = "demo", fetcher = "fetchgit", with = { url = "unused" } } }`,
		) ==
		nil,
		"packages.lua",
	)

	v := new(data)
	defer close(v)

	src := `
makac.luals_setup()

assert(#makac._luals_stub > 0, "embedded stub must be non-empty")
local stub = makac.fs.read_file(makac.data_dir .. "/makac.lua")
assert(stub == makac._luals_stub, "base stub must be installed verbatim")

local link = makac.fs.stat(makac.data_dir .. "/pkgs/demo")
assert(link ~= nil and link.type == "link", "alias must be a symlink")
local direct = makac.fs.read_file(makac.data_dir .. "/packages/demo/lib/util.lua")
assert(direct == "lib-marker\n", "direct read: " .. tostring(direct))
local through = makac.fs.read_file(makac.data_dir .. "/pkgs/demo/util.lua")
assert(through == "lib-marker\n", "alias read: " .. tostring(through))

local root = assert(makac.data_dir:match("^(.*)/[^/]+$"), "data dir has a parent")
local luarc = root .. "/.luarc.json"
local generated = assert(makac.fs.read_file(luarc), ".luarc.json must be created")
assert(generated:find("workspace.library", 1, true), "must list workspace.library")

-- a hand-written .luarc.json must be preserved, never clobbered
makac.fs.write_file(luarc, "CUSTOM\n")
makac.luals_setup()
assert(makac.fs.read_file(luarc) == "CUSTOM\n", "existing .luarc.json must be preserved")
`
	err, ok := run_string(v, src, "test_luals_setup")
	if !ok {
		testing.expectf(t, false, "luals_setup installs the stub + alias: %s", err.message)
		delete(err.message)
		return
	}
	testing.expect(t, true, "luals_setup installs the stub + alias")
}

// luals_setup points workspace.library at exactly ONE root (the data dir):
// other keys are preserved, and the aliases are built from the package
// definitions (fetched and filesystem alike) without loading any package.
@(test)
test_luals_setup_single_root :: proc(t: ^testing.T) {
	root, rerr := os.make_directory_temp("", "makac_luals_merge_*", context.allocator)
	testing.expect(t, rerr == nil, "temp dir")
	defer delete(root)
	defer os.remove_all(root)
	data := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(data) == nil, "data dir")
	luarc := strings.concatenate([]string{root, "/.luarc.json"}, context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			luarc,
			`{"diagnostics.globals":["vim"],"workspace.library":["/old/root"]}`,
		) ==
		nil,
		"seed luarc",
	)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{data, "/packages/inside/lib"}, context.temp_allocator),
		) ==
		nil,
		"inside lib",
	)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{root, "/extpkg/lib"}, context.temp_allocator),
		) ==
		nil,
		"ext lib",
	)
	pkgs := strings.concatenate(
		[]string{
			"return {\n",
			`  { id = "inside", fetcher = "fetchgit", with = { url = "unused" } },`,
			"\n",
			`  { id = "ext", fetcher = "filesystem", with = { path = "`,
			root,
			`/extpkg" } },`,
			"\n}\n",
		},
		context.temp_allocator,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{data, "/packages.lua"}, context.temp_allocator),
			pkgs,
		) ==
		nil,
		"packages.lua",
	)

	v := new(data)
	defer close(v)

	src := strings.concatenate(
		[]string{
			`
makac.luals_setup()
local cfg = makac.json.loads(assert(makac.fs.read_file("`,
			luarc,
			`")))
assert(cfg["diagnostics.globals"][1] == "vim", "other keys must be preserved")
local lib = cfg["workspace.library"]
assert(#lib == 1 and lib[1] == "./.makac", "workspace.library must be exactly the one data-dir root")
-- the require alias exists for every package, in the data dir
assert(makac.fs.stat(makac.data_dir .. "/pkgs/inside") ~= nil, "inside alias")
assert(makac.fs.stat(makac.data_dir .. "/pkgs/ext") ~= nil, "external alias")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, src, "test_luals_single_root")
	if !ok {
		testing.expectf(t, false, "luals_setup single root: %s", err.message)
		delete(err.message)
		return
	}
	testing.expect(t, true, "luals_setup uses a single root")
}
