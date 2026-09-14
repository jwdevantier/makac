// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:testing"

import lua "vendor:lua/5.4"

// makac.pid_alive (design/stdlib.md, "Processes (flat — orchestrator
// vocabulary)") — ONE kill(pid, 0); a boolean answer, never a raise.

// pid_alive is registered FLAT on the makac table (orchestrator vocabulary),
// not under makac.fs nor any submodule.
@(test)
test_pid_alive_registered :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.pid_alive) == "function", "pid_alive must be a function")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// pid_alive of our OWN pid must be true.
@(test)
test_pid_alive_self :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	script := fmt.tprintf(_PID_SELF_SRC, int(posix.getpid()))
	err, ok := run_string(v, script)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	expect_global_bool(t, v, "got", true, "pid_alive(own pid) must return true")
}

// An absurd pid (2^30) must report false WITHOUT raising — the boolean
// answer is the point (handle.md probes poll this until it flips).
@(test)
test_pid_alive_absurd :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	script := fmt.tprintf(_PID_SELF_SRC, 1 << 30)
	err, ok := run_string(v, script)
	defer delete(err.message)
	if !testing.expect(t, ok, "absurd pid must not raise") {
		log_time_err(t, err)
		return
	}
	expect_global_bool(t, v, "got", false, "pid_alive(2^30) must be false")
}

// A freshly-exited-and-reaped pid must be false: fork a child that exits
// instantly, reaped by waitpid; the pid then refers to a process gone.
@(test)
test_pid_alive_reaped :: proc(t: ^testing.T) {
	child := posix.fork()
	if child < 0 {
		testing.fail(t)
		return
	}
	if child == 0 {
		posix._exit(0)
	}
	status: c.int
	waited := posix.waitpid(child, &status, {})
	testing.expect(t, waited == child, "waitpid must reap the child")

	v := new()
	defer close(v)
	script := fmt.tprintf(_PID_SELF_SRC, int(child))
	err, ok := run_string(v, script)
	defer delete(err.message)
	if !testing.expect(t, ok, "reaped pid must not raise") {
		log_time_err(t, err)
		return
	}
	expect_global_bool(t, v, "got", false, "pid_alive(reaped pid) must be false")
}

// Bad argument TYPES raise per convention (argument misuse, not a syscall
// result): strings and empty calls both error.
@(test)
test_pid_alive_bad_types_raise :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	bad := []string{`makac.pid_alive("x")`, `makac.pid_alive()`, `makac.pid_alive({})`}
	for src in bad {
		err, ok := run_string(v, src)
		testing.expect(t, !ok, fmt.tprintf("`%s` must raise", src))
		testing.expect(t, len(err.message) > 0, "raise must carry a message")
		delete(err.message)
	}
}

_PID_SELF_SRC :: `got = makac.pid_alive(%d)`

// Read a global boolean from the Lua state and compare — run_string discards
// chunk results (pcall(L, 0, 0, 0)), so scripts stash their answer in `got`.
expect_global_bool :: proc(t: ^testing.T, v: ^VM, name: cstring, want: bool, msg: string) {
	L := v.state
	lua.getglobal(L, name)
	got := lua.toboolean(L, -1)
	lua.pop(L, 1)
	testing.expect(t, got == b32(want), msg)
}
