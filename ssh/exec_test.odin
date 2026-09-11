// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package ssh

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

/*
The exec helpers are tested without a real ssh/scp binary or a VM: a
stub shell script installed in a temp directory is put on PATH, and it
records its argv (one arg per line) to the file named in the
STUB_ARGS env var, exiting with the status from STUB_EXIT.
*/

// --- stub scaffolding -------------------------------------------------------

// Concatenate two runtime strings into a fresh temp-allocator allocation.
// These strings are short-lived (used within the test setup and freed at
// scope exit), so the temp allocator keeps the tests free of heap leaks.
join :: proc(a, b: string) -> string {
	return strings.join([]string{a, b}, "", context.temp_allocator)
}

/// Write executable stub scripts named `names` into `dir`. Each stub
/// dumps its argv (one arg per line) to $STUB_ARGS and exits with
/// $STUB_EXIT (default 0).
install_stubs :: proc(t: ^testing.T, dir: string, names: ..string) {
	script :=
		"#!/bin/sh\n" +
			"if [ -n \"$STUB_ARGS\" ]; then\n" +
			"  printf '%s\\n' \"$@\" > \"$STUB_ARGS\"\n" +
			"fi\n" +
			"exit \"${STUB_EXIT:-0}\"\n"

	for n in names {
		p := join(dir, join("/", n))
		e := os.write_entire_file_from_string(
			p,
			script,
			os.Permissions_Read_Write_All + os.Permissions_Execute_All,
		)
		if !testing.expectf(t, e == nil, "write stub %s: %s", p, os.error_string(e)) {
			return
		}
	}
}

/// Build the child environment used to run the stub binaries: PATH
/// points only at `stub` (so the stub is found without touching the
/// parent's PATH), and STUB_ARGS / STUB_EXIT tell the stub where to
/// record argv and what status to exit with. Because this is the
/// child's *whole* environment (set per-process via run_process's
/// `child_env`), concurrent tests cannot interfere with one another.
///
/// The returned slice is allocated from the temp allocator and must not
/// outlive the calling test's scope.
stub_child_env :: proc(stub, args_file, exit_code: string) -> []string {
	// The child's *whole* environment is `env`, so build it on the heap
	// (a slice literal returned here would escape the stack frame -- the
	// compiler refuses that outright when it can see it). Each entry must
	// be a proper `KEY=VALUE` line, or the kernel drops it and the stub
	// (found only via `PATH`) would not be executed.
	env := make([]string, 3, context.temp_allocator)
	env[0] = join("PATH=", stub)
	env[1] = join("STUB_ARGS=", args_file)
	env[2] = join("STUB_EXIT=", exit_code)
	return env
}

/// Compare the stub's recorded argv (one arg per line) with `expected`.
check_argv :: proc(t: ^testing.T, file: string, expected: []string) -> bool {
	data, e := os.read_entire_file_from_path(file, context.allocator)
	defer delete(data)
	if !testing.expectf(t, e == nil, "read argv file %s: %s", file, os.error_string(e)) {
		return false
	}
	expected_content := ""
	for s in expected {
		expected_content = join(expected_content, join(s, "\n"))
	}
	return testing.expectf(
		t,
		string(data) == expected_content,
		"argv mismatch\n---- got ----\n%s\n---- want ----\n%s",
		string(data),
		expected_content,
	)
}

/// A scratch area: a temp `base` dir plus an empty `stub` dir for the
/// fake binaries. The caller cleans up `base` (the helper returns
/// before the test body runs, so it cannot defer that itself).
test_area :: proc(t: ^testing.T) -> (base: string, stub: string) {
	base = test_temp_dir(t)
	if base == "" {
		return "", ""
	}

	stub = join(base, "/stub")
	if !testing.expect(t, os.make_directory_all(stub) == nil) {
		return base, ""
	}
	return
}

// --- execute_ssh ------------------------------------------------------------

@(test)
test_execute_ssh_with_command :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "ssh")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	err := execute_ssh(cfg, 2222, "uname -a", child_env = env)
	if !testing.expectf(t, err.kind == .None, "execute_ssh failed: %s", error_string(err)) {
		return
	}
	check_argv(t, args_file, {"-F", cfg, "-p", "2222", "localhost", "uname -a"})
}

@(test)
test_execute_ssh_interactive :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "ssh")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	err := execute_ssh(cfg, 2222, "", child_env = env)
	if !testing.expectf(t, err.kind == .None, "execute_ssh failed: %s", error_string(err)) {
		return
	}
	// An empty command means an interactive session: no trailing arg.
	check_argv(t, args_file, {"-F", cfg, "-p", "2222", "localhost"})
}

@(test)
test_execute_ssh_nonzero_exit :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "ssh")

	env := stub_child_env(stub, "", "3")

	cfg := join(base, "/ssh.conf")
	err := execute_ssh(cfg, 2222, "true", child_env = env)
	testing.expectf(t, err.kind == .NonZero_Exit, "expected NonZero_Exit, got %v", err.kind)
	testing.expectf(t, err.exit_code == 3, "expected exit code 3, got %d", err.exit_code)
}

@(test)
test_execute_ssh_spawn_failure :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	// The stub dir has no ssh binary -> the spawn must fail.
	env := stub_child_env(stub, "", "0")

	cfg := join(base, "/ssh.conf")
	err := execute_ssh(cfg, 2222, "true", child_env = env)
	testing.expectf(t, err.kind == .Spawn_Failed, "expected Spawn_Failed, got %v", err.kind)
}

@(test)
test_execute_ssh_invalid_args :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	// Keep PATH pointed at the empty stub dir, so the *valid* case
	// below fails at spawn instead of running a real ssh.
	env := stub_child_env(stub, "", "0")

	err := execute_ssh("", 22, "c", child_env = env)
	testing.expect(t, err.kind == .Invalid_Arg)

	err = execute_ssh("/cfg", 0, "c", child_env = env)
	testing.expect(t, err.kind == .Invalid_Arg)

	err = execute_ssh("/cfg", -1, "c", child_env = env)
	testing.expect(t, err.kind == .Invalid_Arg)

	err = execute_ssh("/cfg", 65536, "c", child_env = env)
	testing.expect(t, err.kind == .Invalid_Arg)

	err = execute_ssh("/cfg", 65535, "c", child_env = env)
	testing.expect(t, err.kind == .Spawn_Failed) // 65535 is valid -> the spawn must fail
}

// --- scp_put / scp_get --------------------------------------------------------

@(test)
test_scp_put_file :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "scp")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	local := join(base, "/file.txt")
	f, e := os.create(local)
	if !testing.expectf(t, e == nil, "create local file: %s", os.error_string(e)) {
		return
	}
	_ = os.close(f)

	err := scp_put(cfg, 2222, local, "remote.txt", false, child_env = env)
	if !testing.expectf(t, err.kind == .None, "scp_put failed: %s", error_string(err)) {
		return
	}
	// A plain file: no -r.
	check_argv(t, args_file, {"-F", cfg, "-P", "2222", local, "localhost:remote.txt"})
}

@(test)
test_scp_put_dir_automatic_r :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "scp")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	local_dir := join(base, "/dir")
	if !testing.expect(t, os.make_directory_all(local_dir) == nil) {
		return
	}

	err := scp_put(cfg, 2222, local_dir, "rdir", false, child_env = env)
	if !testing.expectf(t, err.kind == .None, "scp_put failed: %s", error_string(err)) {
		return
	}
	// Uploading a directory enables -r automatically.
	check_argv(t, args_file, {"-F", cfg, "-P", "2222", "-r", local_dir, "localhost:rdir"})
}

@(test)
test_scp_get :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "scp")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	local := join(base, "/out.txt")

	err := scp_get(cfg, 2222, "remote.txt", local, false, child_env = env)
	if !testing.expectf(t, err.kind == .None, "scp_get failed: %s", error_string(err)) {
		return
	}
	check_argv(t, args_file, {"-F", cfg, "-P", "2222", "localhost:remote.txt", local})
}

@(test)
test_scp_get_recursive :: proc(t: ^testing.T) {
	base, stub := test_area(t)
	if base == "" || stub == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	install_stubs(t, stub, "scp")

	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	cfg := join(base, "/ssh.conf")
	local_dir := join(base, "/outdir")

	err := scp_get(cfg, 2222, "rdir", local_dir, true, child_env = env)
	if !testing.expectf(t, err.kind == .None, "scp_get failed: %s", error_string(err)) {
		return
	}
	// -r only when explicitly requested for downloads.
	check_argv(t, args_file, {"-F", cfg, "-P", "2222", "-r", "localhost:rdir", local_dir})
}

@(test)
test_transfer_invalid_args :: proc(t: ^testing.T) {
	err := scp_put("", 22, "l", "r", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_put("/c", 0, "l", "r", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_put("/c", 22, "", "r", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_put("/c", 22, "l", "", false)
	testing.expect(t, err.kind == .Invalid_Arg)

	err = scp_get("", 22, "r", "l", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_get("/c", 70000, "r", "l", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_get("/c", 22, "", "l", false)
	testing.expect(t, err.kind == .Invalid_Arg)
	err = scp_get("/c", 22, "r", "", false)
	testing.expect(t, err.kind == .Invalid_Arg)
}

// --- run_process -------------------------------------------------------------

@(test)
test_run_process_spawn_failure :: proc(t: ^testing.T) {
	err := run_process("definitely_missing_cmd_xyz", {})
	testing.expectf(t, err.kind == .Spawn_Failed, "expected Spawn_Failed, got %v", err.kind)
}

@(test)
test_run_process_invalid_arg :: proc(t: ^testing.T) {
	err := run_process("", {})
	testing.expect(t, err.kind == .Invalid_Arg)
}

// --- memory management -------------------------------------------------------

@(test)
test_exec_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	base := test_temp_dir(t)
	if base == "" {
		return
	}
	defer os.remove_all(base)
	defer free_string_alloc(base, context.allocator)
	stub := join(base, "/stub")
	testing.expect(t, os.make_directory_all(stub) == nil)

	install_stubs(t, stub, "ssh")
	args_file := join(base, "/args.txt")
	env := stub_child_env(stub, args_file, "0")

	// Success path: the call's temp allocations must not survive.
	cfg := join(base, "/ssh.conf")
	n_before := len(track.allocation_map)
	err := execute_ssh(cfg, 2222, "x", temp = alloc, child_env = env)
	testing.expectf(t, err.kind == .None, "execute_ssh failed: %s", error_string(err))
	testing.expectf(
		t,
		len(track.allocation_map) == n_before,
		"success path leaked %d allocations",
		len(track.allocation_map) - n_before,
	)

	// Failure path: errors are plain values, so nothing is allocated
	// and there is nothing to free.
	n_before = len(track.allocation_map)
	err = execute_ssh("", 22, "x", temp = alloc, child_env = env)
	testing.expect(t, err.kind == .Invalid_Arg)
	testing.expectf(
		t,
		len(track.allocation_map) == n_before,
		"failure path leaked %d allocations",
		len(track.allocation_map) - n_before,
	)
}
