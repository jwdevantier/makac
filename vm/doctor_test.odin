// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:os"
import "core:strings"
import "core:testing"

// makac._doctor (design/doctor.md): a package's <pkg-root>/health.lua is
// loaded and called with (health, "pkgs/<id>"); the runner returns the number
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
			strings.concatenate([]string{pkg, "/makac.lua"}, context.temp_allocator),
			"return {}\n",
		) ==
		nil,
		"makac.lua",
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
			`return { { id = "demo", fetcher = "filesystem", with = { path = "`,
			pkg,
			`" } } }`,
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
