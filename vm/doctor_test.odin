// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:os"
import "core:strings"
import "core:testing"

// makac._doctor (design/doctor.md): a package's <pkg-root>/health.lua is
// loaded and called with (health, "pkgs/<alias>"); the runner returns the number
// of error findings (which is what makes the CLI exit non-zero).
@(test)
test_doctor_package_checks :: proc(t: ^testing.T) {
	root, rerr := os.make_directory_temp("", "makac_doctor_*", context.allocator)
	testing.expect(t, rerr == nil, "temp dir")
	defer delete(root)
	defer os.remove_all(root)
	data := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)
	pkg := strings.concatenate([]string{root, "/pkg"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(data) == nil, "data dir")
	testing.expect(
		t,
		os.make_directory_all(strings.concatenate([]string{pkg, "/lib"}, context.temp_allocator)) == nil,
		"pkg lib dir",
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{pkg, "/makac_package.lua"}, context.temp_allocator),
			`return {}`,
		) ==
		nil,
		"makac_package.lua",
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{pkg, "/lib/util.lua"}, context.temp_allocator),
			"return {}\n",
		) ==
		nil,
		"lib/util.lua",
	)
	pkgs := strings.concatenate(
		[]string{
			`return { inputs = { ["demo.pkg"] = { fetcher = "filesystem", with = { path = "`,
			pkg,
			`" } } }, packages = { demo = "demo.pkg" } }`,
		},
		context.temp_allocator,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{root, "/makac_project.lua"}, context.temp_allocator),
			pkgs,
		) ==
		nil,
		"makac_project.lua",
	)

	v := new(data)
	defer close(v)

	health := strings.concatenate([]string{pkg, "/health.lua"}, context.temp_allocator)

	// a check that reports an error -> one error finding
	testing.expect(
		t,
		os.write_entire_file_from_string(
			health,
			`return function(health, pkg_name) health.error("broken", "fix it") end`,
		) ==
		nil,
		"health.lua (error)",
	)
	n, called, err := call_string_int(v, "makac._doctor", "demo")
	if err.message != "" {
		testing.expectf(t, false, "doctor: %s", err.message)
		delete(err.message)
		return
	}
	testing.expect(t, called, "makac._doctor must exist")
	testing.expectf(t, n == 1, "expected 1 error finding, got %d", n)

	// a check that uses pkg_name to require its own lib, and passes -> zero
	testing.expect(
		t,
		os.write_entire_file_from_string(
			health,
			`return function(health, pkg_name)
				assert(pcall(require, pkg_name .. "/util"))
				health.ok("fine")
			end`,
		) ==
		nil,
		"health.lua (ok)",
	)
	n2, _, err2 := call_string_int(v, "makac._doctor", "demo")
	delete(err2.message)
	testing.expectf(t, n2 == 0, "expected 0 error findings, got %d", n2)
}

// makac._doctor reports every unmet `requires` as its own error line — the
// wiring check the revamp exists to catch — and returns the count, so the CLI
// exits non-zero exactly like `makac run` does.
@(test)
test_doctor_reports_unmet_requires :: proc(t: ^testing.T) {
	root, rerr := os.make_directory_temp("", "makac_doctor_req_*", context.allocator)
	testing.expect(t, rerr == nil, "temp dir")
	defer delete(root)
	defer os.remove_all(root)
	data := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)
	main_pkg := strings.concatenate([]string{root, "/main"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(data) == nil, "data dir")
	testing.expect(t, os.make_directory_all(main_pkg) == nil, "main pkg dir")
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{main_pkg, "/makac_package.lua"}, context.temp_allocator),
			`return { requires = { dep = "main needs dep", other = "main needs other" } }`,
		) ==
		nil,
		"main manifest",
	)

	project_path := strings.concatenate([]string{root, "/makac_project.lua"}, context.temp_allocator)
	project1 := strings.concatenate(
		[]string{
			`return { inputs = { main = { fetcher = "filesystem", with = { path = "`,
			main_pkg,
			`" } } }, packages = { main = "main" } }`,
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file_from_string(project_path, project1) == nil, "project file (unwired)")

	// two missing dependencies -> two error findings, not one
	v := new(data)
	defer close(v)
	n, called, err := call_string_int(v, "makac._doctor", "main")
	if err.message != "" {
		testing.expectf(t, false, "doctor: %s", err.message)
		delete(err.message)
		return
	}
	testing.expect(t, called, "makac._doctor must exist")
	testing.expectf(t, n == 2, "expected 2 error findings (one per missing dep), got %d", n)

	// wire both aliases to one package -> the findings clear
	dep_pkg := strings.concatenate([]string{root, "/dep"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(dep_pkg) == nil, "dep pkg dir")
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{dep_pkg, "/makac_package.lua"}, context.temp_allocator),
			`return {}`,
		) ==
		nil,
		"dep manifest",
	)
	project2 := strings.concatenate(
		[]string{
			`return { inputs = { main = { fetcher = "filesystem", with = { path = "`,
			main_pkg,
			`" } }, dep = { fetcher = "filesystem", with = { path = "`,
			dep_pkg,
			`" } } }, packages = { main = "main", dep = "dep", other = "dep" } }`,
		},
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file_from_string(project_path, project2) == nil, "project file (wired)")
	v2 := new(data)
	defer close(v2)
	n2, _, err2 := call_string_int(v2, "makac._doctor", "main")
	if err2.message != "" {
		testing.expectf(t, false, "doctor (wired): %s", err2.message)
		delete(err2.message)
		return
	}
	testing.expectf(t, n2 == 0, "expected 0 error findings once wired, got %d", n2)
}
