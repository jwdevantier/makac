// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package datadir

import "core:os"
import "core:path/filepath"
import "core:testing"

T :: testing.T

// Join path parts using the temp allocator.
join :: proc(parts: ..string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

test_temp_dir :: proc(t: ^testing.T) -> string {
	path, e := os.make_directory_temp("", "makac_datadir_test", context.allocator)
	if !testing.expectf(t, e == nil, "make temp dir: %s", os.error_string(e)) {
		return ""
	}
	return path
}

// resolve finds `.makac` directly in the start directory.
@(test)
test_resolve_in_cwd :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	testing.expect(t, os.make_directory_all(join(base, ".makac")) == nil)

	dir, err := resolve(base)
	defer delete(dir)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, dir, join(base, ".makac"))
}

// resolve finds `.makac` in an ancestor of the start directory.
@(test)
test_resolve_in_ancestor :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	testing.expect(t, os.make_directory_all(join(base, ".makac")) == nil)
	testing.expect(t, os.make_directory_all(join(base, "a", "b")) == nil)

	dir, err := resolve(join(base, "a", "b"))
	defer delete(dir)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, dir, join(base, ".makac"))
}

// `.git` without `.makac` triggers creation of `.makac` at the repo root,
// even when invoked from a subdirectory of it.
@(test)
test_resolve_git_triggers_create :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	testing.expect(t, os.make_directory_all(join(base, "repo", ".git")) == nil)
	testing.expect(t, os.make_directory_all(join(base, "repo", "sub")) == nil)

	dir, err := resolve(join(base, "repo", "sub"))
	defer delete(dir)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, dir, join(base, "repo", ".makac"))
	testing.expect(t, os.is_dir(join(base, "repo", ".makac")), ".makac must have been created")
}

// Reaching the filesystem root with neither `.makac` nor `.git` errors.
@(test)
test_resolve_root_errors :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	// Walk up from a fresh temp dir; neither /tmp nor / should carry a
	// `.makac` or `.git` in the test environment.
	dir, err := resolve(base)
	testing.expect_value(t, err, Error.Not_Found)
	testing.expect_value(t, dir, "")
}

// init with a bare path creates `<path>/.makac`.
@(test)
test_init_plain_path :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	target := join(base, "proj")
	testing.expect_value(t, init(target), Error.None)
	testing.expect(t, os.is_dir(join(target, ".makac")))
}

// init with a path ending in `.makac` creates exactly that directory.
@(test)
test_init_makac_suffix :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	target := join(base, "proj", ".makac")
	testing.expect_value(t, init(target), Error.None)
	testing.expect(t, os.is_dir(target))
	// and must NOT have created a nested `.makac/.makac`
	testing.expect(t, !os.is_dir(join(target, ".makac")))
}

// init is idempotent: initializing an already-existing `.makac` succeeds.
@(test)
test_init_idempotent :: proc(t: ^T) {
	base := test_temp_dir(t)
	if base == "" {return}
	defer os.remove_all(base)
	defer delete(base)

	target := join(base, "proj")
	testing.expect_value(t, init(target), Error.None)
	testing.expect_value(t, init(target), Error.None)
	testing.expect(t, os.is_dir(join(target, ".makac")))
}
