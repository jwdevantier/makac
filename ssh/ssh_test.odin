// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package ssh

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// --- helpers ---------------------------------------------------------------

// Concatenate the given strings without a separator. Uses the temp
// allocator so these helper strings auto-free at scope exit and don't
// contribute to leak counts under strict memory tracking.
t_join :: proc(parts: ..string) -> string {
	res, _ := strings.join(parts, "", context.temp_allocator)
	return res
}

/// Create a fresh temp directory for a test.
/// The returned path is allocated from `context.allocator` and is
/// caller-owned; clean up with os.remove_all + free_string_alloc.
test_temp_dir :: proc(t: ^testing.T) -> string {
	path, e := os.make_directory_temp("", "oqqmgr_ssh_test", context.allocator)
	if !testing.expectf(t, e == nil, "make temp dir: %s", os.error_string(e)) {
		return ""
	}
	return path
}

/// Free a string allocated from `a` (no-op when empty).
free_string_alloc :: proc(s: string, a: runtime.Allocator) {
	if len(s) > 0 {
		delete(s, a)
	}
}

/// Read a whole file into a string; "" (and a failed expectation) on error.
read_file_string :: proc(t: ^testing.T, path: string) -> string {
	data, e := os.read_entire_file_from_path(path, context.allocator)
	defer delete(data)
	if !testing.expectf(t, e == nil, "read %s: %s", path, os.error_string(e)) {
		return ""
	}
	return string(data)
}

// --- generate_config --------------------------------------------------------

@(test)
test_generate_happy :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	data_dir := t_join(base, "/vm")

	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlMaster"] = "auto"
	global["ControlPersist"] = "10m"
	global["ControlPath"] = "ssh/ctrl-%r@%h-%p"
	global["ServerAliveCountMax"] = i64(3)
	global["ServerAliveInterval"] = i64(300)
	global["StrictHostKeyChecking"] = "no"
	global["UserKnownHostsFile"] = "/dev/null"
	global["User"] = "root"
	global["HostKeyAlgorithms"] = "+ssh-rsa"
	global["PubkeyAcceptedKeyTypes"] = "+ssh-rsa"
	global["UseKeychain"] = true
	global["FloatOpt"] = f64(3.5)

	vm: Option_Table = make(Option_Table)
	defer delete(vm)
	vm["port"] = i64(22022)
	vm["vm_port"] = i64(22)
	vm["IdentityFile"] = "~/.ssh/id_ed25519"
	vm["User"] = "vboxuser"

	path, err := generate_config(data_dir, global, vm)
	if !testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err)) {
		return
	}
	defer free_string_alloc(path, context.allocator)

	expected :=
		t_join(
			"ControlMaster auto\n",
			"ControlPath ", data_dir, "/ssh/ctrl-%r@%h-%p\n",
			"ControlPersist 10m\n",
			"FloatOpt 3.5\n",
			"HostKeyAlgorithms +ssh-rsa\n",
			"PubkeyAcceptedKeyTypes +ssh-rsa\n",
			"ServerAliveCountMax 3\n",
			"ServerAliveInterval 300\n",
			"StrictHostKeyChecking no\n",
			"UseKeychain true\n",
			"User root\n",
			"UserKnownHostsFile /dev/null\n",
			"IdentityFile ~/.ssh/id_ed25519\n",
			"User vboxuser\n",
		)

	content := read_file_string(t, path)
	if !testing.expectf(
		t, content == expected,
		"content mismatch\n---- got ----\n%s\n---- want ----\n%s",
		content,
		expected,
	) {
		return
	}

	testing.expectf(t, path == t_join(data_dir, "/ssh.conf"), "unexpected path %s", path)
	testing.expectf(t, os.is_directory(t_join(data_dir, "/ssh")), "control dir missing")
}

@(test)
test_generate_relative_data_dir :: proc(t: ^testing.T) {
	// A relative data_dir must still yield an absolute config path, and
	// the ControlPath rewrite must anchor in that absolute location.
	data_dir := fmt.tprintf("ssh_rel_%d", time.to_unix_nanoseconds(time.now()))
	defer os.remove_all(data_dir)

	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlPath"] = "ctrl.sock"
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	path, err := generate_config(data_dir, global, vm)
	if !testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err)) {
		return
	}
	defer free_string_alloc(path, context.allocator)

	testing.expectf(t, os.is_absolute_path(path), "expected absolute path, got %s", path)

	// The content must be addressable purely through the returned
	// (absolute) path -- no help from the caller's relative data_dir.
	control_dir := os.dir(path)
	expected := t_join("ControlPath ", control_dir, "/ssh/ctrl.sock\n")
	testing.expectf(
		t,
		read_file_string(t, path) == expected,
		"expected rewritten ControlPath, got %s",
		read_file_string(t, path),
	)
	testing.expectf(t, os.is_directory(t_join(data_dir, "/ssh")), "control dir missing")
}

@(test)
test_generate_control_path_absolute :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlMaster"] = "auto"
	global["ControlPath"] = "/abs/ctrl-%r@%h-%p"
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	path, err := generate_config(t_join(base, "/vm"), global, vm)
	if !testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err)) {
		return
	}
	defer free_string_alloc(path, context.allocator)

	testing.expectf(
		t,
		read_file_string(t, path) == "ControlMaster auto\nControlPath /abs/ctrl-%r@%h-%p\n",
		"absolute ControlPath must be written verbatim: %s",
		read_file_string(t, path),
	)
}

@(test)
test_generate_control_path_non_string :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	// A non-string ControlPath is written with the %v formatting,
	// unrewritten (matches the Go original's fallback).
	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlPath"] = i64(123)
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	path, err := generate_config(t_join(base, "/vm"), global, vm)
	if !testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err)) {
		return
	}
	defer free_string_alloc(path, context.allocator)

	testing.expect(
		t,
		read_file_string(t, path) == "ControlPath 123\n",
	)
}

@(test)
test_generate_creates_nested_dirs :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	data_dir := t_join(base, "/a/b/c")
	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlMaster"] = "auto"
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	path, err := generate_config(data_dir, global, vm)
	if !testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err)) {
		return
	}
	defer free_string_alloc(path, context.allocator)

	testing.expectf(t, os.is_directory(data_dir), "data dir missing")
	testing.expectf(t, os.is_directory(t_join(data_dir, "/ssh")), "control dir missing")
	testing.expect(t, os.exists(path))
}

@(test)
test_generate_invalid_arg :: proc(t: ^testing.T) {
	global: Option_Table = make(Option_Table)
	defer delete(global)
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	_, err := generate_config("", global, vm)
	testing.expectf(t, err.kind == .Invalid_Arg, "expected Invalid_Arg, got %v", err.kind)
	testing.expect(t, len(err.msg) > 0)
}

@(test)
test_generate_mkdir_failed :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	// Force a mkdir failure by routing data_dir through an existing *file*.
	file := t_join(base, "/afile")
	f, e := os.create(file)
	if !testing.expectf(t, e == nil, "create blocker file: %s", os.error_string(e)) {
		return
	}
	_ = os.close(f)

	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlMaster"] = "auto"
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	_, err := generate_config(t_join(file, "/sub"), global, vm)
	testing.expectf(t, err.kind == .Mkdir_Failed, "expected Mkdir_Failed, got %v", err.kind)
}

@(test)
test_generate_write_failed :: proc(t: ^testing.T) {
	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)

	// Pre-create ssh.conf as a *directory*; opening it for writing fails.
	data_dir := t_join(base, "/w")
	e: os.Error
	e = os.make_directory_all(t_join(data_dir, "/ssh.conf"))
	if !testing.expectf(t, e == nil, "pre-create ssh.conf dir: %s", os.error_string(e)) {
		return
	}

	global: Option_Table = make(Option_Table)
	defer delete(global)
	global["ControlMaster"] = "auto"
	vm: Option_Table = make(Option_Table)
	defer delete(vm)

	_, err := generate_config(data_dir, global, vm)
	testing.expectf(t, err.kind == .Write_Failed, "expected Write_Failed, got %v", err.kind)
}

@(test)
test_generate_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	base, e := os.make_directory_temp("", "oqqmgr_ssh_leak", alloc)
	if !testing.expectf(t, e == nil, "make temp dir: %s", os.error_string(e)) {
		return
	}
	defer os.remove_all(base)

	// The tables are tracked-allocator owned; the helper's own bookkeeping
	// (make / delete of the map) is internal, so free the tables before
	// asserting on the map, but *after* the call that used them.
	global := make(Option_Table, alloc)
	global["ControlMaster"] = "auto"
	global["ControlPath"] = "ssh/ctrl-%r@%h-%p"
	vm := make(Option_Table, alloc)
	vm["port"] = i64(2222)

	path, err := generate_config(t_join(base, "/vm"), global, vm, perm = alloc, temp = alloc)
	testing.expectf(t, err.kind == .None, "generate failed: %s", error_string(err))

	delete(global)
	delete(vm)
	free_string_alloc(base, alloc)

	if err.kind == .None {
		free_string_alloc(path, alloc)
	}

	testing.expectf(
		t,
		len(track.allocation_map) == 0,
		"leaked %d allocations",
		len(track.allocation_map),
	)
}

// --- error_string -----------------------------------------------------------

@(test)
test_error_string :: proc(t: ^testing.T) {
	testing.expect(t, error_string(Error{}) == "no error")

	// Exit status is appended for NonZero_Exit.
	s := error_string(Error{kind = .NonZero_Exit, msg = "ssh", exit_code = 3})
	testing.expectf(t, strings.contains(s, "3"), "expected exit code in %q", s)
	testing.expectf(t, strings.contains(s, "ssh"), "expected msg in %q", s)

	// A plain kind renders its base message.
	s = error_string(Error{kind = .Invalid_Arg})
	testing.expect(t, s == "invalid argument")
}
