// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:testing"

import lua "vendor:lua/5.4"

// makac.spawn (design/stdlib.md, "Processes (flat)" / "Launching
// long-lived processes"). Detached fork, stdio to files, WNOHANG status,
// no :kill, no GC kill. All waits poll status() with tiny makac.time.sleep
// gaps; children are real but trivial (sh -c), self-reaped by the scripts.

// spawn is registered FLAT on the makac table, carrying a "makac.proc"
// userdata with pid + status.
@(test)
test_spawn_registered :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.spawn) == "function", "spawn must be a function")
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// The happy path, end to end: a sh -c child that sleeps, drops a marker
// file, prints to stdout and echoes to stderr — each stream to ITS file;
// status() reports "running" first, then { code = 0 } (reaped, cached).
@(test)
test_spawn_lifecycle :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fs = makac.fs
		local dir = tostring(fs.mktemp_dir("makac_spawn_life"))
		local marker = dir .. "/marker.txt"
		local out = dir .. "/out.log"
		local ferr = dir .. "/err.log"
		local cmd = "sleep 0.2; echo MARK > '" .. marker .. "'; echo OUTLINE; echo ELINE >&2"
		local p = makac.spawn({"sh", "-c", cmd}, { stdout = out, stderr = ferr })
		assert(type(p) == "userdata", "spawn returns a userdata proc")
		g_pid = p.pid
		assert(type(p.pid) == "number" and p.pid > 0, "pid must be a positive integer")
		assert(tostring(p):match("^makac%.proc"), "tostring names makac.proc")
		g_first = p:status()
		local st
		for i = 1, 2000 do
			st = p:status()
			if st ~= "running" then break end
			makac.time.sleep(10 * makac.time.ns_per_ms)
		end
		assert(st ~= "running", "child must exit within 20s")
		g_code = st.code
		-- cached: a repeat call reports the same reaped result
		g_code2 = p:status().code
		g_out = fs.read_file(out)
		g_err = fs.read_file(ferr)
		g_marker = fs.read_file(marker)
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	l_expect_global_string(t, v, "g_first", "running", "status() is \"running\" while the child sleeps")
	l_expect_global_int(t, v, "g_pid", 1, "pid > 0", op = .GREATER)
	l_expect_global_int(t, v, "g_code", 0, "status() code after exit")
	l_expect_global_int(t, v, "g_code2", 0, "status() repeats the cached reaped result")
	l_expect_global_string(t, v, "g_out", "OUTLINE\n", "child stdout lands in its file")
	l_expect_global_string(t, v, "g_err", "ELINE\n", "child stderr lands in its file")
	l_expect_global_string(t, v, "g_marker", "MARK\n", "marker written by the child")
}

// Exit codes are DATA: a command exiting 3 immediately reports { code = 3 }.
@(test)
test_spawn_exit_code :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fs = makac.fs
		local dir = tostring(fs.mktemp_dir("makac_spawn_exit"))
		local p = makac.spawn(
			{"sh", "-c", "exit 3"},
			{ stdout = dir .. "/out.log", stderr = dir .. "/err.log" }
		)
		local st
		for i = 1, 2000 do
			st = p:status()
			if st ~= "running" then break end
			makac.time.sleep(10 * makac.time.ns_per_ms)
		end
		assert(st ~= "running", "child must exit within 20s")
		assert(st.code == 3, "exit 3 must report code 3, got: " .. tostring(st.code))
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// A nonexistent program: spawn itself SUCCEEDS (the failure happens in the
// child after fork, whose exec error exits 127 — there is nothing to raise).
@(test)
test_spawn_missing_program :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fs = makac.fs
		local dir = tostring(fs.mktemp_dir("makac_spawn_noent"))
		local p = makac.spawn(
			{"definitely-not-a-real-program-makac-test"},
			{ stdout = dir .. "/out.log", stderr = dir .. "/err.log" }
		)
		assert(p.pid > 0)
		local st
		for i = 1, 2000 do
			st = p:status()
			if st ~= "running" then break end
			makac.time.sleep(10 * makac.time.ns_per_ms)
		end
		assert(st ~= "running", "child must exit within 20s")
		assert(st.code == 127, "failed exec must report 127, got: " .. tostring(st.code))
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
	}
}

// Argument misuse raises: non-table argv, empty argv, non-string element,
// missing/illegal stdout/stderr opts. (Errors raise; the child's exit code
// is the only result that is data.)
@(test)
test_spawn_bad_args_raise :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	bad := []string{
		`makac.spawn()`,
		`makac.spawn("ls", { stdout = "a", stderr = "b" })`,
		`makac.spawn({}, { stdout = "a", stderr = "b" })`,
		`makac.spawn({{}}, { stdout = "a", stderr = "b" })`,
		`makac.spawn({"true"}, { stderr = "b" })`,
		`makac.spawn({"true"}, { stdout = "a" })`,
		`makac.spawn({"true"}, { stdout = 42, stderr = "b" })`,
		`makac.spawn({"true"})`,
	}
	for src in bad {
		err, ok := run_string(v, src)
		testing.expect(t, !ok, fmt.tprintf("`%s` must raise", src))
		testing.expect(t, len(err.message) > 0, "raise must carry a message")
		delete(err.message)
	}
}

// Detached means detached: when the spawn call returns, the proc object is
// the ONLY handle — no pipe output leaks onto the parent's stdout (asserted
// structurally above: stdout goes to its file), and a GC'd proc does not
// kill the child (there is no way to observe that without sleeping on the
// child pid, which pid_alive covers: collect garbage, the pid stays alive).
@(test)
test_spawn_gc_never_kills :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fs = makac.fs
		local dir = tostring(fs.mktemp_dir("makac_spawn_gc"))
		local pid
		do
			local p = makac.spawn(
				{"sh", "-c", "sleep 5"},
				{ stdout = dir .. "/out.log", stderr = dir .. "/err.log" }
			)
			pid = p.pid
		end
		collectgarbage("collect")
		collectgarbage("collect")
		makac.time.sleep(50 * makac.time.ns_per_ms)
		assert(makac.pid_alive(pid), "a GC'd proc must NOT kill the child")
		g_gcpid = pid
		-- no :kill method, by design — exec covers it: clean up after ourselves
		makac.exec({"kill", tostring(pid)})
		`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		log_time_err(t, err)
		return
	}
	// The killed child is a zombie until reaped (nobody waitpids it); reap
	// it from Odin so the suite leaves no orphans behind.
	lua.getglobal(v.state, "g_gcpid")
	gcpid := posix.pid_t(lua.tointeger(v.state, -1))
	lua.pop(v.state, 1)
	st: c.int
	testing.expect(t, posix.waitpid(gcpid, &st, {}) == gcpid, "killed GC'd child must be reapable")
}

_Spawn_Op :: enum {
	EQUAL,
	GREATER,
}

// Read a global integer from the Lua state and compare.
l_expect_global_int :: proc(
	t: ^testing.T,
	v: ^VM,
	name: cstring,
	want: int,
	msg: string,
	op: _Spawn_Op = .EQUAL,
	loc := #caller_location,
) {
	L := v.state
	ty := lua.getglobal(L, name)
	defer lua.pop(L, 1)
	if !testing.expect(t, ty == c.int(lua.Type.NUMBER), fmt.tprintf("global %v must be a number", name), loc = loc) {
		return
	}
	got := int(lua.tointeger(L, -1))
	switch op {
	case .EQUAL:
		testing.expect(t, got == want, fmt.tprintf("%s: want %d, got %d", msg, want, got), loc = loc)
	case .GREATER:
		testing.expect(t, got > want, fmt.tprintf("%s: want > %d, got %d", msg, want, got), loc = loc)
	}
}

// Read a global string from the Lua state and compare.
l_expect_global_string :: proc(
	t: ^testing.T,
	v: ^VM,
	name: cstring,
	want: string,
	msg: string,
	loc := #caller_location,
) {
	L := v.state
	ty := lua.getglobal(L, name)
	defer lua.pop(L, 1)
	if !testing.expect(t, ty == c.int(lua.Type.STRING), fmt.tprintf("global %v must be a string", name), loc = loc) {
		return
	}
	l: c.size_t
	s := lua.tolstring(L, -1, &l)
	got := string(([^]u8)(s)[:int(l)])
	testing.expect(t, got == want, fmt.tprintf("%s: want %q, got %q", msg, want, got), loc = loc)
}
