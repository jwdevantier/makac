// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import dl "../downloader"

T :: testing.T

// A VM can be created and closed without crashing.
@(test)
test_new_close :: proc(t: ^T) {
	v := new()
	testing.expect(t, v != nil, "new must return a VM")
	testing.expect(t, v.state != nil, "VM must hold a Lua state")
	close(v)
}

// Creating and closing many VMs back to back must not leak or crash
// (the test runner tracks allocations and reports leaks).
@(test)
test_new_close_many :: proc(t: ^T) {
	for _ in 0 ..< 8 {
		v := new()
		testing.expect(t, v != nil)
		close(v)
	}
}

// A simple script evaluates without error.
@(test)
test_run_string_hello :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(v, `print("hello world")`)
	defer delete(err.message)
	if !testing.expect(t, ok, "expected evaluation to succeed") {
		return
	}
	testing.expect(t, err.message == "")
}

// A syntax error must surface as a non-empty, meaningful error message.
@(test)
test_run_string_syntax_error :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(v, "this is not lua", "@bad.lua")
	defer delete(err.message)
	testing.expect(t, !ok, "expected evaluation to fail")
	testing.expect(t, len(err.message) > 0, "expected a non-empty error message")
	// The chunk name should appear so the user can tell where it broke.
	testing.expect(t, strings.contains(err.message, "bad.lua"), "expected chunk name in error")
}

// A runtime error must surface the error value (`error("boom")`).
@(test)
test_run_string_runtime_error :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(v, `error("boom")`)
	defer delete(err.message)
	testing.expect(t, !ok, "expected evaluation to fail")
	testing.expect(t, len(err.message) > 0, "expected a non-empty error message")
	testing.expect(t, strings.contains(err.message, "boom"), "expected 'boom' in error")
}

// makac.exec runs a program directly and captures its exit code and stdout..
@(test)
test_exec_echo :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"echo", "hello"})
		assert(r.code == 0, "expected code 0, got " .. tostring(r.code))
		assert(r.stdout:find("hello"), "expected 'hello' in stdout, got: " .. r.stdout)
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// stdout and stderr are captured separately.
@(test)
test_exec_stderr_separate :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"sh", "-c", "echo out; echo err >&2"})
		assert(r.code == 0)
		assert(r.stdout:find("out"), "expected 'out' in stdout, got: " .. r.stdout)
		assert(r.stderr:find("err"), "expected 'err' in stderr, got: " .. r.stderr)
		assert(not r.stdout:find("err"), "stderr leaked into stdout")
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// join=true: stderr writes into stdout's descriptor at spawn (2>&1), so the
// merged stream keeps true interleaved order and stderr comes back empty.
@(test)
test_exec_join_streams :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"sh", "-c", "echo one; echo two >&2; echo three"}, { join = true })
		assert(r.code == 0, r.code)
		assert(r.stderr == "", "join must leave stderr empty, got: " .. r.stderr)
		-- all three lines, IN ORDER (interleave order survives the shared pipe)
		local a, b, c = r.stdout:find("one"), r.stdout:find("two"), r.stdout:find("three")
		assert(a and b and c and a < b and b < c, "expected one/two/three in order, got: " .. r.stdout)

		-- combine with stdin and env too, and on a remote-ish nonzero exit
		local r2 = makac.exec({"sh", "-c", "cat; echo E$TAG >&2; exit 3"},
			{ join = true, stdin = "piped-in\n", env = { TAG = "7" } })
		assert(r2.code == 3, r2.code)
		assert(r2.stdout == "piped-in\nE7\n", r2.stdout)

		-- separate capture is unchanged when join is absent/false
		local r3 = makac.exec({"sh", "-c", "echo o; echo e >&2"}, { join = false })
		assert(r3.stdout == "o\n" and r3.stderr == "e\n")
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// timeout_s: an overrun child gets TERM (1s grace) then KILL; the run
// returns promptly with timed_out = true and partial output intact. Timeouts
// are data; never an error. (Wall-clock bounded — must never take 30s.)
@(test)
test_exec_timeout :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- plain timeout: TERM kills sh promptly
		local started = os.clock()
		local r = makac.exec({"sh", "-c", "sleep 30"}, { timeout_s = 0.3 })
		assert(os.clock() - started < 5, "timeout must return promptly")
		assert(r.timed_out == true, "timed_out must be set")

		-- TERM-ignoring child: escalates to KILL after the 1s grace
		started = os.clock()
		local r2 = makac.exec({"sh", "-c", "trap '' TERM; sleep 30"}, { timeout_s = 0.3 })
		assert(os.clock() - started < 5, "KILL must follow the grace period")
		assert(r2.timed_out == true)

		-- a fast command inside its timeout: untouched
		local r3 = makac.exec({"true"}, { timeout_s = 5 })
		assert(r3.timed_out == false and r3.code == 0)

		-- partial output survives the timeout
		local r4 = makac.exec({"sh", "-c", "echo before-hang; sleep 30"}, { timeout_s = 0.3 })
		assert(r4.timed_out and r4.stdout:find("before%-hang"), r4.stdout)

		-- validation
		local ok1, e1 = pcall(makac.exec, {"true"}, { timeout_s = -1 })
		assert(not ok1 and tostring(e1):find("not be negative"), tostring(e1))
		local ok2, e2 = pcall(makac.exec, {"true"}, { timeout_s = "soon" })
		assert(not ok2 and tostring(e2):find("a number"), tostring(e2))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// A timed-out run must kill the child's whole process
// GROUP — a `sh -c "sleep 30 & wait"` step must not orphan its sleep (an
// orphaned grandchild holding inherited pipe write ends is exactly how a
// finished run's output never reaches EOF). The grandchild's pid lands in a
// pidfile before the timeout fires; afterwards pid_alive must flip false
// (with a grace window: init reaps the orphan asynchronously).
@(test)
test_exec_timeout_kills_grandchildren :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fs = makac.fs
		local dir = tostring(fs.mktemp_dir("makac_exec_gckill"))
		local pidfile = dir .. "/pid"
		-- fork a grandchild and wait on it: the timeout's TERM/KILL must
		-- reach BOTH (the group), not just the shell
		local r = makac.exec(
			{"sh", "-c", "sleep 30 & echo $! > '" .. pidfile .. "'; wait"},
			{ timeout_s = 0.3 }
		)
		assert(r.timed_out == true, "timed_out must be set")
		local pid = tonumber(fs.read_file(pidfile))
		assert(type(pid) == "number", "pidfile must hold the grandchild pid")
		-- the group KILL is synchronous with the run's return, but the
		-- orphan is reaped by init asynchronously: poll pid_alive briefly
		local deadline = os.clock() + 5
		while makac.pid_alive(pid) do
			assert(os.clock() < deadline, "grandchild survived the group kill")
			makac.time.sleep(50 * makac.time.ns_per_ms)
		end
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

when ODIN_OS == .Linux {
	// An exec'd child closes every inherited fd above 2
	// before exec — QMP sockets, capture pipes, and the test runner's own
	// plumbing must not leak into steps. /proc/self/fd of the child lists
	// nothing above the stdio slots (the one extra entry is the directory ls
	// itself opened to list them).
	@(test)
	test_exec_child_closes_inherited_fds :: proc(t: ^T) {
		v := new()
		defer close(v)
		err, ok := run_string(
			v,
			`
			local r = makac.exec({"ls", "/proc/self/fd"})
			assert(r.code == 0, r.stdout .. r.stderr)
			for entry in r.stdout:gmatch("[^\n]+") do
				local n = tonumber(entry)
				assert(n and n <= 3, "inherited fd leaked into child: " .. entry)
			end
		`,
		)
		defer delete(err.message)
		testing.expect(t, ok, err.message)
	}
}

// on_line: complete lines stream to the callback as they arrive, per stream;
// trailing partial line flushes at EOF; a raising callback aborts the child
// and the error propagates.
@(test)
test_exec_on_line :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- lines per stream, in order; full capture intact regardless
		local got = {}
		local r = makac.exec({"sh", "-c", "echo a; echo b >&2; echo c"}, {
			on_line = function(line, stream)
				got[#got + 1] = stream .. ":" .. line
			end,
		})
		assert(r.code == 0)
		assert(r.stdout == "a\nc\n" and r.stderr == "b\n")
		assert(got[1] == "stdout:a", got[1] or "nil")
		-- order guaranteed WITHIN a stream; across streams delivery races
		local ia, ic
		for i, s in ipairs(got) do
			if s == "stdout:a" then ia = i end
			if s == "stdout:c" then ic = i end
		end
		assert(ia and ic and ia < ic, table.concat(got, ","))
		assert(table.concat(got, ","):find("stderr:b", 1, true), table.concat(got, ","))

		-- join=true: one stream, true interleave order
		local gotj = {}
		makac.exec({"sh", "-c", "echo x; echo y >&2"}, {
			join = true,
			on_line = function(line, stream) gotj[#gotj + 1] = stream .. ":" .. line end,
		})
		assert(gotj[1] == "stdout:x" and gotj[2] == "stdout:y", table.concat(gotj, ","))

		-- a trailing line without \n flushes at EOF
		local gotp = {}
		makac.exec({"sh", "-c", "printf partial"}, {
			on_line = function(line) gotp[#gotp + 1] = line end,
		})
		assert(#gotp == 1 and gotp[1] == "partial", tostring(gotp[1]))

		-- a raising callback aborts the child (no 30s sleep!) and propagates
		local started = os.clock()
		local ok1, e1 = pcall(makac.exec, {"sh", "-c", "echo first; sleep 30; echo never"}, {
			on_line = function() error("stop here") end,
		})
		assert(not ok1 and tostring(e1):find("stop here"), tostring(e1))
		assert(os.clock() - started < 5, "callback abort must kill the child")

		-- validation
		local ok2, e2 = pcall(makac.exec, {"true"}, { on_line = 42 })
		assert(not ok2 and tostring(e2):find("a function"), tostring(e2))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// shell action: join/timeout_s/on_line pass through the host target.
@(test)
test_shell_join_timeout_on_line :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- join via the shell action: true interleave into out.stdout
		local r = step { uses = "shell", with = {
			cmd = { "sh", "-c", "echo o1; echo e1 >&2; echo o2" }, join = true,
		} }
		assert(r.out.stderr == "", r.out.stderr)
		local a, b, c = r.out.stdout:find("o1"), r.out.stdout:find("e1"), r.out.stdout:find("o2")
		assert(a and b and c and a < b and b < c, r.out.stdout)

		-- timeout via the shell action: timed_out surfaces, default error
		local ok1, e1 = pcall(step, { uses = "shell", with = {
			cmd = { "sh", "-c", "sleep 30" }, timeout_s = 0.2,
		} })
		assert(not ok1 and tostring(e1):find("timed out"), tostring(e1))
		-- ... or as data with ignore_exit_code
		local r2 = step { uses = "shell", with = {
			cmd = { "sh", "-c", "sleep 30" }, timeout_s = 0.2,
			ignore_exit_code = true,
		} }
		assert(r2.out.timed_out == true)

		-- on_line via the shell action
		local seen = {}
		step { uses = "shell", with = {
			cmd = { "sh", "-c", "echo l1; echo l2" },
			on_line = function(l) seen[#seen + 1] = l end,
		} }
		assert(seen[1] == "l1" and seen[2] == "l2", table.concat(seen, ","))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// A non-zero exit code is data, not an error.
@(test)
test_exec_nonzero_exit :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"sh", "-c", "exit 3"})
		assert(r.code == 3, "expected code 3, got " .. tostring(r.code))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// opts.chdir sets the child's working directory.
@(test)
test_exec_chdir :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"sh", "-c", "pwd"}, {chdir = "/tmp"})
		assert(r.code == 0)
		assert(r.stdout:find("/tmp"), "expected cwd /tmp, got: " .. r.stdout)
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// opts.env entries are merged on top of the current environment.
@(test)
test_exec_env :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec(
			{"sh", "-c", "echo $MAKAC_TEST_VAR"},
			{env = {MAKAC_TEST_VAR = "xyzzy"}}
		)
		assert(r.code == 0)
		assert(r.stdout:find("xyzzy"), "expected env var value, got: " .. r.stdout)
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// opts.stdin feeds non-interactive input to the child.
@(test)
test_exec_stdin :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local r = makac.exec({"cat"}, {stdin = "piped in"})
		assert(r.code == 0)
		assert(r.stdout:find("piped in"), "expected stdin echoed, got: " .. r.stdout)
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// A program that cannot be spawned raises a Lua error.
@(test)
test_exec_spawn_failure :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local pok, perr = pcall(makac.exec, {"definitely-not-a-real-program-makac-xyz"})
		assert(not pok, "expected pcall to fail")
		assert(perr:find("failed to spawn"), "unexpected error: " .. tostring(perr))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// The embedded prelude is evaluated by new() before any user-facing Lua:
// scripts can use things only the prelude defines.
@(test)
test_prelude_available :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		assert(type(makac.registry) == "table")
		assert(type(makac.registry.actions) == "table")
		assert(type(makac.registry.fetchers) == "table")
		-- prelude preserved Odin-side primitives already under makac
		assert(type(makac.exec) == "function")
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// Action machinery: define -> run -> normalized result shape.
@(test)
test_action_machinery :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		makac.define_action("hello", function(with)
			return { out = { n = (with and with.base or 0) + 42 } }
		end)
		-- defaults filled
		local r = makac.run_action("hello", { base = 0 })
		assert(r.changed == false and r.skipped == false
			and r.err == nil and r.out.n == 42)
		-- 'with' may be omitted
		r = makac.run_action("hello")
		assert(r.out.n == 42)
		-- defaults preserved when action sets fields
		makac.define_action("mut", function() return { changed = true } end)
		r = makac.run_action("mut")
		assert(r.changed == true and type(r.out) == "table")
		-- opts.default_name is remembered for step
		makac.define_action("named", function() return {} end,
			{ default_name = "default step name" })
		assert(makac.registry.action_default_names.named == "default step name")
		-- duplicate registration raises
		assert(not pcall(makac.define_action, "named", function() return {} end))
		-- unknown action raises, naming the action
		local uok, uerr = pcall(makac.run_action, "nope")
		assert(not uok and tostring(uerr):find("'nope'"))
		-- <pkg>:<action> resolves in the same registry; unknown (unloaded)
		-- package actions raise a clear 'unknown action' error
		local eok, eerr = pcall(makac.run_action, "qemu:vm")
		assert(not eok and tostring(eerr):find("unknown action 'qemu:vm'"))
		-- an action that errors propagates a message naming the action
		makac.define_action("boom", function() error("kablam") end)
		local bok, berr = pcall(makac.run_action, "boom")
		assert(not bok and tostring(berr):find("'boom'")
			and tostring(berr):find("kablam"))
		-- an action returning a non-table raises
		makac.define_action("bad", function() return 7 end)
		local aok, aerr = pcall(makac.run_action, "bad")
		assert(not aok and tostring(aerr):find("'bad'")
			and tostring(aerr):find("number"))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// The built-in `shell` action, host path (design/action_shell.md).
@(test)
test_shell_action :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- echo: stdout captured, code 0, changed always true, err unset
		local r = makac.run_action("shell", { cmd = {"echo", "yow"} })
		assert(r.out.stdout == "yow\n" and r.out.code == 0)
		assert(r.changed == true and r.err == nil and r.skipped == false)
		assert(type(makac.run_action("shell", {cmd = {"true"}}).out.stderr) == "string")
		-- separate stdout/stderr capture; output is the lossy join
		local s = makac.run_action("shell",
			{ cmd = {"sh", "-c", "echo o; echo e >&2"} })
		assert(s.out.stdout == "o\n" and s.out.stderr == "e\n"
			and s.out.output == "o\ne\n" and s.err == nil)
		-- failing command: err set (code + context), out.code, still changed
		local f = makac.run_action("shell", { cmd = {"sh", "-c", "echo nope >&2; exit 7"} })
		assert(f.err ~= nil and f.out.code == 7 and f.changed == true)
		assert(f.err:find("code 7") and f.err:find("nope"), f.err)
		-- ignore_exit_code: err stays nil
		local g = makac.run_action("shell",
			{ cmd = {"sh", "-c", "exit 7"}, ignore_exit_code = true })
		assert(g.err == nil and g.out.code == 7)
		-- default_name registered for step
		assert(makac.registry.action_default_names.shell == "run shell command")
		-- chdir/env/stdin forwarded to exec
		local e = makac.run_action("shell",
			{ cmd = {"sh", "-c", "tr a-z A-Z"}, stdin = "abc\n",
			  env = { SHELL_ACT_TEST = "1" } })
		assert(e.out.stdout == "ABC\n" and e.err == nil, e.err)
		-- missing cmd raises; non-string cmd elements raise
		local cok, cerr = pcall(makac.run_action, "shell", {})
		assert(not cok and tostring(cerr):find("with%.cmd"), cerr)
		-- the 'shell' arg is IGNORED on the host (see design/action_shell.md)
		r = makac.run_action("shell", { cmd = {"true"}, shell = "/bin/bash" })
		assert(r.err == nil)
		-- 'with.target' must be a real target; a host target runs locally,
		-- a remote one gets the shell -c wrapping (design/action_shell.md)
		local tok, terr = pcall(makac.run_action, "shell",
			{ cmd = {"true"}, target = {} })
		assert(not tok and tostring(terr):find("must be a target"), terr)
		r = makac.run_action("shell", { cmd = {"true"}, target = makac.host })
		assert(r.err == nil)
		local captured
		local fake_remote = makac.make_target("remote", "nowhere", {
			run = function(_t, argv, opts)
				captured = { argv = argv, opts = opts }
				return { code = 0, stdout = "", stderr = "" }
			end,
			put = function() end, get = function() end })
		r = makac.run_action("shell", { cmd = {"echo", "hi there"}, target = fake_remote,
			env = { A = "1", B = "two words" }, shell = "/bin/bash", chdir = "/w" })
		assert(r.err == nil)
		-- cmd and opts pass STRAIGHT through (task17); the shell -c "<env>
		-- <argv>" wrapping is the remote target's run op's business (task16)
		assert(captured.argv[1] == "echo" and captured.argv[2] == "hi there")
		assert(captured.opts.shell == "/bin/bash" and captured.opts.chdir == "/w")
		assert(captured.opts.env.A == "1" and captured.opts.env.B == "two words")
		-- shell omitted: passed through as nil (the remote run op defaults
		-- to /bin/sh when env assignments or shell make wrapping necessary)
		r = makac.run_action("shell", { cmd = {"true"}, target = fake_remote })
		assert(captured.argv[1] == "true" and captured.opts.shell == nil)
		fake_remote:close()
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// step {} executes the action immediately (no deferring), returns the
// normalized result, resolves a default name when none is given, and aborts
// the workflow (raises) when the action reports failure via result.err.
@(test)
test_step :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- a custom action proves step calls through the registry machinery
		local called = 0
		makac.define_action("touch_counter", function(with)
			called = called + 1
			return { changed = true, out = { count = called, msg = with.msg } }
		end, { default_name = "touch the counter" })
		local r = step { uses = "touch_counter", with = { msg = "hi" } }
		-- executed immediately, result returned, defaults filled in
		assert(called == 1)
		assert(r.out.count == 1 and r.out.msg == "hi")
		assert(r.changed == true and r.err == nil and r.skipped == false)
		-- steps sit inside plain control flow: run twice in a loop
		for i = 1, 2 do step { uses = "touch_counter", with = {} } end
		assert(step { uses = "touch_counter", with = {} }.out.count == 4)
		-- shell through step: result shape intact
		local s = step { name = "say yow", uses = "shell",
			with = { cmd = {"echo", "yow"} } }
		assert(s.out.stdout == "yow\n" and s.out.code == 0)

		-- unknown action: step raises, naming the step
		local uok, uerr = pcall(step, { name = "mystep", uses = "nope" })
		assert(not uok)
		assert(tostring(uerr):find("mystep") and tostring(uerr):find("nope"), tostring(uerr))

		-- failing action: err surfaces as a raised error naming the step,
		-- so the workflow aborts at the failing line
		local fok, ferr = pcall(step, { uses = "shell",
			with = { cmd = {"sh", "-c", "echo bad >&2; exit 3"} } })
		assert(not fok)
		ferr = tostring(ferr)
		assert(ferr:find("run shell command") -- default name of shell
			and ferr:find("code 3") and ferr:find("bad"), ferr)
		-- with an explicit name the message names it instead
		fok, ferr = pcall(step, { name = "explode", uses = "shell",
			with = { cmd = {"false"} } })
		assert(not fok and tostring(ferr):find("explode"), tostring(ferr))

		-- spec validation
		assert(not pcall(step, {}), "missing uses must fail")
		assert(not pcall(step, { uses = "shell", with = "nope" }),
			"with must be a table")
		assert(not pcall(step, "uses-string"), "spec must be a table")
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// `facts` action: namespaces map to finders (built-in by name or custom
// function), each namespace lands under res.out.facts.<ns>; gathering never
// reports a change. Built-in `os` and `env` finders run on the host for now.
@(test)
test_facts_action :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- built-in finders by name
		local f = step { uses = "facts", with = { finders = {
			os = "os", env = "env" } } }
		assert(f.err == nil and f.changed == false, "facts never changes state")
		assert(type(f.out.facts) == "table")
		assert(type(f.out.facts.os) == "table")
		assert(f.out.facts.os.arch == "x86_64" or f.out.facts.os.arch == "aarch64",
			"unexpected arch: " .. tostring(f.out.facts.os.arch))
		assert(type(f.out.facts.os.os) == "string" and #f.out.facts.os.os > 0)
		-- env: PATH is always present in a spawned environment
		assert(type(f.out.facts.env.PATH) == "string", "env finder must expose PATH")

		-- custom function finder, plus mixing with a built-in
		local c = step { name = "custom facts", uses = "facts", with = { finders = {
			host = "env",
			mine = function(_target) return { answer = 42, nested = { a = 1 } } end,
		} } }
		assert(c.out.facts.mine.answer == 42 and c.out.facts.mine.nested.a == 1)
		assert(type(c.out.facts.host.USER) == "string" or type(c.out.facts.host.HOME) == "string")

		-- default name registered for bare step {}
		assert(makac.registry.action_default_names.facts == "gather facts")

		-- validation
		local vok, verr = pcall(step, { uses = "facts", with = {} })
		assert(not vok and tostring(verr):find("with%.finders"), tostring(verr))
		vok, verr = pcall(step, { uses = "facts",
			with = { finders = { x = "no-such-finder" } } })
		assert(not vok and tostring(verr):find("no%-such%-finder"), tostring(verr))
		vok, verr = pcall(step, { uses = "facts",
			with = { finders = { x = 3 } } })
		assert(not vok and tostring(verr):find("namespace 'x'"), tostring(verr))
		vok, verr = pcall(step, { uses = "facts",
			with = { finders = { x = function() return 5 end } } })
		assert(not vok and tostring(verr):find("expected a table"), tostring(verr))
		-- failing finder aborts the step, naming the namespace
		vok, verr = pcall(step, { uses = "facts", with = { finders = {
			x = function() error("kaboom", 0) end } } })
		assert(not vok and tostring(verr):find("kaboom")
			and tostring(verr):find("namespace 'x'"), tostring(verr))
		-- with.target must be a real target; the host target works
		vok, verr = pcall(step, { uses = "facts",
			with = { finders = { os = "os" }, target = {} } })
		assert(not vok and tostring(verr):find("must be a target"), tostring(verr))
		vres = step { uses = "facts",
			with = { finders = { os = "os" }, target = makac.host } }
		assert(vres.out.facts.os.os == "linux")
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// makac.fetch: real HTTPS fetch into <data_dir>/cache keyed by sha256(url),
// exercised through Lua (body content, key shape, cache-hit semantics), with
// checksum verification checked Odin-side around it.
@(test)
test_fetch_over_https :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_fetch_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)

	err, ok := run_string(
		v,
		fmt.tprintf(
			`
		local url = "https://example.com/"
		local prefix = "%s/cache/"
		local p = makac.fetch(url)
		assert(p:sub(1, #prefix) == prefix, "fetched path must live under <data_dir>/cache, got: " .. p)
		local base = p:match("([^/]+)$")
		assert(#base == 64 and base:match("^[0-9a-f]+$"), "cache key must be a sha256 hex digest, got: " .. base)
		local f = io.open(p, "rb"); local body = f:read("a"); f:close()
		assert(body:find("Example Domain", 1, true), "unexpected body from example.com")
		local p2 = makac.fetch(url)  -- cache hit: same slot, no transfer
		assert(p2 == p, "same URL must return the same cache slot")
	`,
			dir,
		),
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
	if !ok {return}

	// Checksum verification: the cached file's own sha256 is accepted...
	key := dl.url_cache_key("https://example.com/", context.temp_allocator)
	file_path := strings.concatenate([]string{dir, "/cache/", key}, context.temp_allocator)
	testing.expect(t, os.exists(file_path), "cache entry must exist after the fetch")
	digest, herr := dl.hash_file(file_path, context.temp_allocator)
	testing.expectf(t, herr == nil, "hash cached file: {}", herr)

	script2 := fmt.tprintf(`assert(makac.fetch("https://example.com/", "%s") ~= nil)`, digest)
	err2, ok2 := run_string(v, script2)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)

	// ...and a wrong checksum is an error (corrupt entry dropped + refetch +
	// mismatch); the entry is not left in place.
	bad := strings.repeat("0", 64, context.temp_allocator)
	err3, ok3 := run_string(
		v,
		fmt.tprintf(
			`local pok, perr = pcall(makac.fetch, "https://example.com/", "%s")
			assert(not pok, "wrong checksum must be an error")
			assert(tostring(perr):find("checksum mismatch"), tostring(perr))`,
			bad,
		),
	)
	defer delete(err3.message)
	testing.expect(t, ok3, err3.message)
	testing.expect(t, !os.exists(file_path), "failed verification must leave no cache entry")
}

// ---------------------------------------------------------------------------
// Loopback HTTP server (in-process): serves one prebuilt response to every
// request, so the REAL curl download path can run in a test with no network
// (the downloader's --proto allowlist is http(s) only — no file://).
// ---------------------------------------------------------------------------

Http_Fixture :: struct {
	ln:   posix.FD,
	port: u16, // host byte order
	resp: string, // owned (context.allocator); freed by _http_stop
	th:   ^thread.Thread,
}

_http_serve :: proc(srv: ^Http_Fixture) {
	context = runtime.default_context()
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	for {
		conn := posix.accept(srv.ln, nil, nil)
		if conn == -1 {return} 	// listener shut down: we're done
		_http_handle(conn, srv.resp)
	}
}

_http_handle :: proc(conn: posix.FD, resp: string) {
	defer posix.close(conn)
	// Drain the request head so curl sees a well-formed exchange; its
	// content is irrelevant here.
	buf: [4096]u8
	got := 0
	for got < len(buf) {
		n := posix.read(conn, &buf[got], uint(len(buf) - got))
		if n <= 0 {break}
		got += int(n)
		if strings.contains(string(buf[:got]), "\r\n\r\n") {break}
	}
	_fake_qmp_write(conn, resp)
}

_http_start :: proc(t: ^T, body: string) -> ^Http_Fixture {
	srv := new_clone(Http_Fixture{}, context.temp_allocator)
	srv.ln = posix.socket(.INET, .STREAM, .IP)
	testing.expect(t, srv.ln != -1, "http fixture: socket")
	addr: posix.sockaddr_in
	addr.sin_family = .INET
	addr.sin_port = 0 // ephemeral
	addr.sin_addr.s_addr = transmute(u32be)([4]u8{127, 0, 0, 1})
	testing.expect(
		t,
		posix.bind(srv.ln, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .OK,
		"http fixture: bind",
	)
	slen := posix.socklen_t(size_of(posix.sockaddr_in))
	testing.expect(
		t,
		posix.getsockname(srv.ln, cast(^posix.sockaddr)&addr, &slen) == .OK,
		"http fixture: getsockname",
	)
	srv.port = u16(u16be(addr.sin_port))
	testing.expect(t, posix.listen(srv.ln, 4) == .OK, "http fixture: listen")
	// The response is prebuilt here: the serve thread performs NO allocation
	// (its context is not the test's; sharing an arena across threads would
	// race).
	srv.resp = fmt.aprintf(
		"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(body),
		body,
		allocator = context.allocator,
	)
	srv.th = thread.create_and_start_with_poly_data(srv, _http_serve)
	return srv
}

_http_stop :: proc(srv: ^Http_Fixture) {
	posix.shutdown(srv.ln, .RDWR) // unblock a pending accept
	thread.join(srv.th)
	thread.destroy(srv.th)
	posix.close(srv.ln)
	delete(srv.resp, context.allocator)
}

// makac.download: with an explicit cache-dir hint it works even in a
// data-dir-less VM; checksum mismatches surface as a clear error. The body
// is served by the loopback HTTP fixture, so the real curl path runs with
// no network.
@(test)
test_download_primitive :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_download_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new()
	defer close(v)

	srv := _http_start(t, "download-marker")
	defer _http_stop(srv)
	url := fmt.aprintf(
		"http://127.0.0.1:%d/payload.bin",
		srv.port,
		allocator = context.temp_allocator,
	)
	// digest of the served body (hash_file wants a file; any copy will do)
	pfile := strings.concatenate([]string{dir, "/payload.bin"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(pfile, "download-marker") == nil)
	digest, herr := dl.hash_file(pfile, context.temp_allocator)
	testing.expectf(t, herr == nil, "hash fixture: {}", herr)
	cache := strings.concatenate([]string{dir, "/hint-cache"}, context.temp_allocator)

	chunk := `
		local p = makac.download("@URL@", "@DIGEST@", "@CACHE@")
		assert(type(p) == "string" and p:sub(1, #"@CACHE@") == "@CACHE@",
			"download must land in the hinted cache dir, got: " .. tostring(p))
		local f = assert(io.open(p, "rb"))
		assert(f:read("a") == "download-marker"); f:close()
		-- cache hit: same path, still verified
		assert(makac.download("@URL@", "@DIGEST@", "@CACHE@") == p)
		-- wrong sha256 -> clear checksum error
		local ok, e = pcall(makac.download, "@URL@", ("0"):rep(64), "@CACHE@")
		assert(not ok, "checksum mismatch must be an error")
		e = tostring(e)
		assert(e:find("makac.download"), e)
		assert(e:find("checksum mismatch"), e)
	`
	r1, _ := strings.replace_all(chunk, "@URL@", url, context.temp_allocator)
	r2, _ := strings.replace_all(r1, "@DIGEST@", string(digest), context.temp_allocator)
	r3, _ := strings.replace_all(r2, "@CACHE@", cache, context.temp_allocator)
	err, ok := run_string(v, r3)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// makac.fetch without a data directory raises a clear error instead of
// fetching somewhere arbitrary.
@(test)
test_fetch_requires_data_dir :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local pok, perr = pcall(makac.fetch, "https://example.com/")
		assert(not pok and tostring(perr):find("no data directory"), tostring(perr))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// fetchurl fetcher end-to-end (offline): the data-dir cache is pre-populated
// with a hand-built tarball, so makac.download is a cache hit; the fetcher
// verifies the sha256 checksum and extracts the tarball (as-is) into
// <data_dir>/packages/<id>/.
@(test)
test_fetchurl_fetcher :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_fetchurl_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)

	// build the tarball fixture (tarball root dir 'pkgroot/'; two copies so
	// two packages can be cached under two url keys)
	// fmt.tprintf cannot be used for Lua sources containing braces (Odin's
	// fmt treats {} as verbs); substitute a placeholder instead
	fixture_chunk, _ := strings.replace_all(
		`
		makac.exec({ "mkdir", "-p", "@DIR@/fixtures/pkgroot/lib" })
		local f = io.open("@DIR@/fixtures/pkgroot/makac.lua", "w")
		f:write("-- pkg-marker\n"); f:close()
		f = io.open("@DIR@/fixtures/pkgroot/lib/hello.lua", "w")
		f:write("-- hello-marker\n"); f:close()
		local r = makac.exec({ "tar", "-czf", "@DIR@/pkg.tar.gz", "-C", "@DIR@/fixtures", "pkgroot" })
		assert(r.code == 0, r.stderr)
		r = makac.exec({ "cp", "@DIR@/pkg.tar.gz", "@DIR@/pkg2.tar.gz" })
		assert(r.code == 0, r.stderr)
	`,
		"@DIR@",
		dir,
		context.temp_allocator,
	)
	err, ok := run_string(v, fixture_chunk)
	defer delete(err.message)
	if !testing.expect(t, ok, err.message) {return}

	// pre-populate the cache: <dir>/cache/sha256(url) for both urls
	url1 := "https://pkgs.invalid/testpkg.tar.gz"
	url2 := "https://pkgs.invalid/nested.tar.gz"
	url3 := "https://pkgs.invalid/custom.tar.gz"
	tar1 := strings.concatenate([]string{dir, "/pkg.tar.gz"}, context.temp_allocator)
	tar2 := strings.concatenate([]string{dir, "/pkg2.tar.gz"}, context.temp_allocator)
	digest, herr := dl.hash_file(tar1, context.temp_allocator)
	testing.expectf(t, herr == nil, "hash fixture tarball: {}", herr)
	cache_dir := strings.concatenate([]string{dir, "/cache"}, context.temp_allocator)
	testing.expect(t, os.mkdir_all(cache_dir, os.perm_number(0o755)) == nil)
	key1_path := strings.concatenate(
		[]string{cache_dir, "/", dl.url_cache_key(url1, context.temp_allocator)},
		context.temp_allocator,
	)
	key2_path := strings.concatenate(
		[]string{cache_dir, "/", dl.url_cache_key(url2, context.temp_allocator)},
		context.temp_allocator,
	)
	key3_path := strings.concatenate(
		[]string{cache_dir, "/", dl.url_cache_key(url3, context.temp_allocator)},
		context.temp_allocator,
	)
	// copy BEFORE the renames move tar1/tar2 away (dst, src)
	tar3 := strings.concatenate([]string{dir, "/pkg3.tar.gz"}, context.temp_allocator)
	testing.expect(t, os.copy_file(tar3, tar2) == nil)
	testing.expect(t, os.rename(tar1, key1_path) == nil)
	testing.expect(t, os.rename(tar2, key2_path) == nil)
	testing.expect(t, os.rename(tar3, key3_path) == nil)

	// packages.lua — a bare table constructor — with ids, fetchers, checksum
	pkgs_tmpl := `{
  { id = "testpkg", fetcher = "fetchurl",
      with = { url = "@URL1@", sha256 = "@DIGEST@", unpacker = "tar" } },
  { id = "github.com/user/nestedpkg", fetcher = "fetchurl",
      with = { url = "@URL2@", sha256 = "@DIGEST@", unpacker = "tar" } },
  { id = "custompkg", fetcher = "fetchurl",
      with = { url = "@URL3@", sha256 = "@DIGEST@",
        -- custom uncompressor: receives the with-args PLUS the downloaded
        -- file path in args.archive
        unpacker = function(args, dst_dir)
          assert(type(args.archive) == "string" and args.archive ~= "",
            "downloaded file path must be injected as args.archive")
          local f = io.open(args.archive, "rb"); assert(f); f:close()
          local r = makac.exec({ "tar", "-xf", args.archive, "-C", dst_dir,
                                 "--strip-components=1" })
          assert(r.code == 0, r.stderr)
        end } },
}`
	r1, _ := strings.replace_all(pkgs_tmpl, "@URL1@", url1, context.temp_allocator)
	r2, _ := strings.replace_all(r1, "@URL2@", url2, context.temp_allocator)
	r3, _ := strings.replace_all(r2, "@URL3@", url3, context.temp_allocator)
	pkgs, _ := strings.replace_all(r3, "@DIGEST@", string(digest), context.temp_allocator)
	pkgs_path := strings.concatenate([]string{dir, "/packages.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(pkgs_path, transmute([]u8)pkgs) == nil)

	err2, ok2 := run_string(
		v,
		`
		assert(makac.data_dir ~= nil and makac.data_dir ~= "", "makac.data_dir must be set")
		assert(makac.fetch_all() == 3)
		local function readfile(p)
			local f = io.open(p, "r"); if not f then return nil end
			local c = f:read("a"); f:close(); return c
		end
		-- "tar" unpacker extracts the tarball as-is (no stripping)
		local mk = readfile(makac.data_dir .. "/packages/testpkg/pkgroot/makac.lua")
		assert(mk and mk:find("pkg-marker", 1, true),
			"tarball extracted as-is: makac.lua at tarball root")
		local lib = readfile(makac.data_dir .. "/packages/github.com/user/nestedpkg/pkgroot/lib/hello.lua")
		assert(lib and lib:find("hello-marker", 1, true), "nested package id directory")
		-- custom unpacker: ran (its --strip-components=1 drops pkgroot/)
		local cmk = readfile(makac.data_dir .. "/packages/custompkg/makac.lua")
		assert(cmk and cmk:find("pkg-marker", 1, true), "custom unpacker output")
	`,
	)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)
}

// packages.lua validation (design/packages.md): every format violation is a
// hard error naming the problem; an empty list is fine.
@(test)
test_fetch_package_list_validation :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_pkgval_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)

	// missing packages.lua
	err, ok := run_string(
		v,
		`
		local ok, e = pcall(makac.fetch_all)
		assert(not ok and tostring(e):find("no package list found"), tostring(e))
	`,
	)
	defer delete(err.message)
	if !testing.expect(t, ok, err.message) {return}

	cases := [?]struct {
		src:     string,
		pattern: string,
	} {
		{`return 42`, "must return a table"},
		{`{ "x" }`, "entry #1 must be a table"},
		{`{ { fetcher = "fetchurl" } }`, "entry #1: 'id' must be a non-empty string"},
		{`{ { id = "a:b", fetcher = "fetchurl" } }`, "must not contain ':'"},
		{`{ { id = "x" } }`, "'fetcher' must be a non-empty string"},
		{`{ { id = "x", fetcher = {} } }`, "'fetcher' must be a non-empty string (fetcher name"},
		{`{ { id = "x", fetcher = "" } }`, "got empty string"},
		{`{ { id = "x", fetcher = "wget" } }`, "no known fetcher named 'wget'"},
		{`{ { id = "x", fetcher = "fetchurl", with = 5 } }`, "'with' must be a table"},
		{`{ { id =`, "failed to parse"},
	}
	pkgs_path := strings.concatenate([]string{dir, "/packages.lua"}, context.temp_allocator)
	for c in cases {
		testing.expect(t, os.write_entire_file(pkgs_path, transmute([]u8)c.src) == nil)
		script := fmt.tprintf(
			`local ok, e = pcall(makac.fetch_all)
			assert(not ok, "expected an error")
			assert(tostring(e):find("%s", 1, true), tostring(e))`,
			c.pattern,
		)
		ferr, fok := run_string(v, script)
		testing.expectf(t, fok, "case %q: %s", c.src, ferr.message)
		delete(ferr.message)
	}

	// empty list: nothing to fetch, no error
	empty_src := "{}"
	testing.expect(t, os.write_entire_file(pkgs_path, transmute([]u8)empty_src) == nil)
	ferr, fok := run_string(v, `assert(makac.fetch_all() == 0)`)
	defer delete(ferr.message)
	testing.expect(t, fok, ferr.message)

	// a fetcher may be given as an inline function; it receives
	// (with-args, dest, id)
	fn_src := `{ { id = "inline", fetcher = function(spec, dest)
		assert(spec.with.greet == "hi")
		assert(spec.id == "inline")
		local r = makac.exec({ "mkdir", "-p", dest })
		assert(r.code == 0)
	end, with = { greet = "hi" } } }`
	testing.expect(t, os.write_entire_file(pkgs_path, transmute([]u8)fn_src) == nil)
	ferr2, fok2 := run_string(
		v,
		`assert(makac.fetch_all() == 1)
		local f = io.open(makac.data_dir .. "/packages/inline", "r")
		assert(f == nil or f:read("a") == nil) -- exists as a dir (or empty)
		if f then f:close() end
		makac.print_package_defs(makac.read_package_defs())`,
	)
	defer delete(ferr2.message)
	testing.expect(t, fok2, ferr2.message)
}

// fetchurl argument validation happens before any network access.
@(test)
test_fetchurl_arg_validation :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fu = makac.registry.fetchers.fetchurl
		assert(type(fu) == "function", "fetchurl must be a built-in fetcher")
		-- spec contract: full entry; 'with' is required
		local ok, e = pcall(fu, { id = "x" }, "/tmp/whatever")
		assert(not ok and tostring(e):find("requires a 'with' table"), tostring(e))
		-- url required, dest required (both validated before any download)
		ok, e = pcall(fu, { id = "x", with = {} }, "")
		assert(not ok and tostring(e):find("with.url"), tostring(e))
		ok, e = pcall(fu, { id = "x", with = { url = "https://x.invalid/y.tgz" } }, "")
		assert(not ok and tostring(e):find("'dest'"), tostring(e))
		-- sha256 is required, 64 hex chars
		ok, e = pcall(fu, { id = "x", with = { url = "https://x.invalid/y.tgz" } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("with.sha256"), tostring(e))
		ok, e = pcall(fu, { id = "x", with = { url = "u", sha256 = "abcd" } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("invalid sha256"), tostring(e))
		-- unpacker is required; "tar" (string) or a function
		local sha = ("0"):rep(64)
		ok, e = pcall(fu, { id = "x", with = { url = "u", sha256 = sha } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("with.unpacker"), tostring(e))
		ok, e = pcall(fu, { id = "x", with = { url = "u", sha256 = sha, unpacker = "zip" } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("unpacker"), tostring(e))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// fetchgit fetcher: clones a repository (offline: a local repo path) into
// <data_dir>/packages/<id>/ (keeping .git so re-fetches update in place) and
// checks out the requested rev.
@(test)
test_fetchgit_fetcher :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_fetchgit_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)

	// build a fixture repo: branch main has "main-marker", branch dev has
	// "dev-marker" in makac.lua
	chunk, _ := strings.replace_all(
		`
		makac.exec({ "mkdir", "-p", "@DIR@/repo" })
		local function git(...)
			local argv = { "git", "-C", "@DIR@/repo", ... }
			local r = makac.exec(argv)
			assert(r.code == 0, table.concat(argv, " ") .. " -> " .. r.stderr)
		end
		local function sh(cmd)
			local r = makac.exec({ "sh", "-c", cmd })
			assert(r.code == 0, cmd .. " -> " .. r.stderr)
		end
		sh("git init -q -b main @DIR@/repo")
		git("config", "user.email", "makac@test.invalid")
		git("config", "user.name", "makac test")
		sh("echo main-marker > @DIR@/repo/makac.lua")
		sh("mkdir -p @DIR@/repo/lib && echo lib-marker > @DIR@/repo/lib/x.lua")
		git("add", "-A")
		git("commit", "-q", "-m", "main commit")
		git("checkout", "-q", "-b", "dev")
		sh("echo dev-marker > @DIR@/repo/makac.lua")
		git("commit", "-qam", "dev commit")
		git("checkout", "-q", "main")
	`,
		"@DIR@",
		dir,
		context.temp_allocator,
	)
	err, ok := run_string(v, chunk)
	defer delete(err.message)
	if !testing.expect(t, ok, err.message) {return}

	// two packages: default branch and the 'dev' ref
	pkgs_tmpl := `{
  { id = "mainpkg", fetcher = "fetchgit", with = { url = "@DIR@/repo" } },
  { id = "devpkg", fetcher = "fetchgit", with = { url = "@DIR@/repo", rev = "dev" } },
}`
	pkgs, _ := strings.replace_all(pkgs_tmpl, "@DIR@", dir, context.temp_allocator)
	pkgs_path := strings.concatenate([]string{dir, "/packages.lua"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(pkgs_path, pkgs) == nil)

	err2, ok2 := run_string(
		v,
		fmt.tprintf(
			`
		assert(makac.fetch_all() == 2)
		local function readfile(p)
			local f = io.open(p, "r"); if not f then return nil end
			local c = f:read("a"); f:close(); return c
		end

		-- pin to an older commit hash (the main commit under dev): content
		-- must differ from the dev tip
		local rev1 = makac.exec({{ "git", "-C", "%s/repo", "rev-parse", "dev~1" }})
			.stdout:gsub("%%s+", "")
		assert(rev1:match("^%%x+$"), rev1)
		local fg = makac.registry.fetchers.fetchgit
		fg({{ id = "pinned", with = {{ url = "%s/repo", rev = rev1 }} }},
			makac.data_dir .. "/packages/pinned")
		local pk = readfile(makac.data_dir .. "/packages/pinned/makac.lua")
		assert(pk and pk:find("main%%-marker"), "pinned to older commit: " .. tostring(pk))
		assert(not pk:find("dev%%-marker"), "must not see dev tip content")
		local mk = readfile(makac.data_dir .. "/packages/mainpkg/makac.lua")
		assert(mk and mk:find("main-marker", 1, true), "default branch content")
		local lib = readfile(makac.data_dir .. "/packages/mainpkg/lib/x.lua")
		assert(lib and lib:find("lib-marker", 1, true), "subdir content copied")
		assert(readfile(makac.data_dir .. "/packages/mainpkg/.git/HEAD") ~= nil,
			"fetchgit keeps .git so fetches are re-runnable")
		local dv = readfile(makac.data_dir .. "/packages/devpkg/makac.lua")
		assert(dv and dv:find("dev-marker", 1, true), "rev=dev content")

		-- re-running a fetch on an existing work tree updates in place
		-- (fetch + checkout) instead of re-cloning
		assert(makac.fetch_all() == 2)
		assert(readfile(makac.data_dir .. "/packages/devpkg/makac.lua"):find("dev%%-marker"),
			"re-fetch keeps dev content")
	`,
			dir,
			dir,
		),
	)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)

	// bad ref is a clear error naming the ref
	err3, ok3 := run_string(
		v,
		fmt.tprintf(
			`
		local ok, e = pcall(makac.registry.fetchers.fetchgit,
			{{ id = "badref", fetcher = "fetchgit",
			   with = {{ url = "%s/repo", rev = "no-such-branch" }} }},
			"%s/packages/badref")
		assert(not ok and tostring(e):find("no-such-branch", 1, true), tostring(e))
	`,
			dir,
			dir,
		),
	)
	defer delete(err3.message)
	testing.expect(t, ok3, err3.message)
}

// fetchgit validates its arguments: 'with.url' is required (design/fetchers.md),
// 'with.rev' must be a non-empty string when given, and dest must be a path.
@(test)
test_fetchgit_arg_validation :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		local fg = makac.registry.fetchers.fetchgit
		assert(type(fg) == "function", "fetchgit must be a built-in fetcher")
		local ok, e = pcall(fg, { id = "some-local-pkg" }, "/tmp/whatever")
		assert(not ok and tostring(e):find("with.url", 1, true), tostring(e))
		ok, e = pcall(fg, { id = "x", with = { url = "" } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("non%-empty string"), tostring(e))
		ok, e = pcall(fg, { id = "x", with = { url = "u", rev = "" } }, "/tmp/whatever")
		assert(not ok and tostring(e):find("with.rev", 1, true), tostring(e))
		ok, e = pcall(fg, { id = "x", with = { url = "u" } }, "")
		assert(not ok and tostring(e):find("'dest'", 1, true), tostring(e))
		-- error level: the message starts with "fetchgit:", not some line number
		ok, e = pcall(fg, 42, "/tmp/whatever")
		assert(not ok, tostring(e))
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
}

// Host target (design/target.md): exists always, is a fixed kind, run captures
// code/stdout/stderr with non-zero exit as DATA, put/get copy (relative
// target-side paths resolving against $HOME), close is idempotent and
// forbids run/put/get afterwards.
@(test)
test_host_target :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_target_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)
	tmpl := `
		local h = makac.host
		assert(makac.is_target(h) and h.kind == "host" and h.name == "host")

		-- run: streams separate, non-zero exit is DATA (not an error)
		local r = h:run({ "sh", "-c", "echo out; echo err >&2; exit 1" })
		assert(r.code == 1 and r.stdout == "out\n" and r.stderr == "err\n")
		-- chdir and env honored
		r = h:run({ "sh", "-c", "pwd; printf $MK_TEST" },
			{ chdir = "@DIR@", env = { MK_TEST = "env-marker" } })
		assert(r.code == 0 and r.stdout:find("@DIR@", 1, true)
			and r.stdout:find("env%-marker"), r.stdout)
		r = h:run({ "false" })
		assert(r.code == 1)

		-- run validation
		local okc, e = pcall(function() h:run({}) end)
		assert(not okc and tostring(e):find("argv%[1%]"), tostring(e))
		okc, e = pcall(function() h:run({ "a", 5 }) end)
		assert(not okc and tostring(e):find("only contain strings"), tostring(e))

		-- put/get roundtrip; relative target-side path resolves against $HOME
		local home = os.getenv("HOME")
		assert(home and home:sub(1, 1) == "/")
		local tmp = os.tmpname()
		h:run({ "rm", "-rf", home .. "/makac-target-test" })
		h:run({ "mkdir", "-p", home .. "/makac-target-test" })
		h:run({ "sh", "-c", "echo payload > " .. tmp })
		h:put(tmp, "makac-target-test/copy.txt")
		r = h:run({ "cat", home .. "/makac-target-test/copy.txt" })
		assert(r.code == 0 and r.stdout == "payload\n", r.stdout)
		h:get("makac-target-test/copy.txt", "@DIR@/got.txt")
		r = h:run({ "cat", "@DIR@/got.txt" })
		assert(r.code == 0 and r.stdout == "payload\n")

		-- recursive copy of a directory
		h:run({ "mkdir", "-p", "@DIR@/d/sub" })
		h:run({ "sh", "-c", "echo nested > @DIR@/d/sub/f" })
		h:put("@DIR@/d", "@DIR@/dcopy")
		r = h:run({ "cat", "@DIR@/dcopy/sub/f" })
		assert(r.code == 0 and r.stdout == "nested\n", r.stdout)

		-- put/get failures are errors (transfer failure, not exit-code data)
		okc, e = pcall(function() h:put("/no/such/file", "@DIR@/x") end)
		assert(not okc and tostring(e):find("put to 'host' failed"), tostring(e))

		h:run({ "rm", "-rf", home .. "/makac-target-test" })

		-- close: idempotent, then run/put/get all fail naming the target
		h:close()
		h:close()
		okc, e = pcall(function() h:run({ "true" }) end)
		assert(not okc and tostring(e):find("closed"), tostring(e))
		okc, e = pcall(function() h:put("a", "b") end)
		assert(not okc and tostring(e):find("closed"), tostring(e))
		okc, e = pcall(function() h:get("a", "b") end)
		assert(not okc and tostring(e):find("closed"), tostring(e))
		assert(not makac.is_target({})) -- shape check exposed
	`
	chunk, _ := strings.replace_all(tmpl, "@DIR@", dir, context.temp_allocator)
	err, ok := run_string(v, chunk)
	defer delete(err.message)
	testing.expect(t, ok, err.message)

	// step's `target` field is shorthand for with.target (design/target.md):
	// it reaches shell action on the host. Using a dedicated VM so the
	// host-close above cannot disturb it.
	v2 := new(dir)
	defer close(v2)
	err2, ok2 := run_string(
		v2,
		`
		-- spec.target reaches the action as with.target
		local seen
		makac.define_action("peek", function(with)
			seen = with.target
			return { changed = false }
		end)
		step { uses = "peek", target = makac.host }
		assert(seen == makac.host)
		-- both spec.target and with.target: rejected
		local dbl, de = pcall(step, { uses = "peek", target = makac.host,
			with = { target = makac.host } })
		assert(not dbl and tostring(de):find("not both"), tostring(de))
		-- non-target value rejected by step
		local nt, ne = pcall(step, { uses = "peek", target = 42 })
		assert(not nt and tostring(ne):find("must be a target"), tostring(ne))
		-- make_target: kinds are fixed; ops required
		local bad, be = pcall(makac.make_target, "container", "x",
			{ run = function() end, put = function() end, get = function() end })
		assert(not bad and tostring(be):find("'host' or 'remote'"), tostring(be))
		-- a custom (remote-shaped) target's close runs its teardown once
		local closes = 0
		local cust = makac.make_target("remote", "cust", {
			run = function() return { code = 0, stdout = "", stderr = "" } end,
			put = function() end, get = function() end,
			close = function() closes = closes + 1 end,
		})
		assert(cust.kind == "remote" and cust.name == "cust")
		cust:close(); cust:close()
		assert(closes == 1, closes)
		-- it landed in the runner's target registry
		local found = false
		for _, tg in ipairs(makac.registry.targets) do
			if tg == cust then found = true end
		end
		assert(found)
	`,
	)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)
}

// Remote (SSH) target primitives (task16). NO live sshd: ssh/scp are stub
// shell scripts on PATH (the ssh package's own stubbing approach) that log
// their argv; the test drives makac.new_ssh_target + a real `shell`-action
// step over it, and verifies the exact ssh/scp argv, config generation,
// stdin piping, non-zero-exit-as-data, and handle lifecycle.
@(test)
test_ssh_target :: proc(t: ^T) {
	base, derr := os.make_directory_temp("", "makac_vm_sshtgt_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	data_dir := fmt.tprintf("%s/.makac", base)
	testing.expect(t, os.make_directory(data_dir) == nil)

	// -- stub ssh/scp ------------------------------------------------------------
	stub_dir := fmt.tprintf("%s/bin", base)
	testing.expect(t, os.make_directory(stub_dir) == nil)
	log_path := fmt.tprintf("%s/stub.log", base)
	stub_script :=
		"#!/bin/sh\n" +
		"line=''; for a in \"$@\"; do line=\"$line<$a>\"; done\n" +
		"printf '%s\\n' \"$line\" >> \"$STUB_LOG\"\n" +
		"cat >/dev/null 2>&1 || true\n" +
		"printf 'stub-stdout\\n'\n" +// drain stdin so makac's stdin write never blocks
		"printf 'stub-stderr\\n' >&2\n" +
		"exit \"${STUB_EXIT:-0}\"\n"
	names := [?]string{"ssh", "scp"}
	for name in names {
		p := fmt.tprintf("%s/%s", stub_dir, name)
		e := os.write_entire_file_from_string(
			p,
			stub_script,
			os.Permissions_Read_Write_All + os.Permissions_Execute_All,
		)
		testing.expectf(t, e == nil, "write stub %s: %s", p, os.error_string(e))
	}
	old_path := os.get_env_alloc("PATH", context.temp_allocator)
	new_path := fmt.ctprintf("%s:%s", stub_dir, old_path)
	posix.setenv("PATH", new_path, true)
	posix.setenv("STUB_LOG", fmt.ctprintf("%s", log_path), true)
	defer posix.setenv("PATH", fmt.ctprintf("%s", old_path), true)
	defer posix.unsetenv("STUB_EXIT")

	// files for put/get
	local_file := fmt.tprintf("%s/payload.txt", base)
	testing.expect(t, os.write_entire_file_from_string(local_file, "payload\n") == nil)
	local_dir := fmt.tprintf("%s/indir", base)
	testing.expect(t, os.make_directory(local_dir) == nil)
	testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/f", local_dir), "x") == nil)

	v := new(data_dir)
	defer close(v)
	tmpl := `
		local tgt = makac.new_ssh_target("vm1", {
			host = "192.0.2.1", user = "root", port = 2222,
			options = { IdentityFile = "~/.k/id" },
		})
		assert(tgt.kind == "remote" and tgt.name == "vm1")
		assert(makac.is_target(tgt))

		-- run op: streams captured, code is data; stdin forwarded
		local res = tgt:run({ "grep", "needle" }, { stdin = "haystack\nneedle\n" })
		assert(res.code == 0 and res.stdout == "stub-stdout\n"
			and res.stderr == "stub-stderr\n", res.stdout)

		-- shell action over the remote: shell -c "<env> <quoted argv>",
		-- with chdir prepended by the target's run op
		local r = step { uses = "shell", target = tgt, with = {
			cmd = { "make", "greeter" },
			env = { NAME = "some one" },
			shell = "/bin/bash",
			chdir = "/work/dir",
		} }
		assert(r.err == nil and r.out.code == 0 and r.out.stdout == "stub-stdout\n")
		assert(r.out.output == "stub-stdout\nstub-stderr\n")

		-- put/get: files auto-recurse directories on put
		tgt:put("@BASE@/payload.txt", "up/there.txt")
		tgt:put("@BASE@/indir", "up/dir")
		tgt:get("down/src.txt", "@BASE@/got.txt")
	`
	chunk, _ := strings.replace_all(tmpl, "@BASE@", base, context.temp_allocator)
	err, ok := run_string(v, chunk)
	defer delete(err.message)
	if !testing.expect(t, ok, err.message) {return}

	// -- what the stubs actually received -----------------------------------------
	log: []u8
	log, _ = os.read_entire_file(log_path, context.temp_allocator)
	// tests run in parallel and PATH/STUB_LOG are process-wide: only lines of
	// THIS test's data dir are ours
	all_lines := strings.split(string(log), "\n", context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for ln in all_lines {
		if strings.contains(ln, data_dir) {append(&lines, ln)}
	}
	// 1: tgt:run({"grep","needle"}) — quoted join, config under the target's
	//    own state dir, right port, localhost transport target
	// (the stub records "$@" only, so the program name itself is not logged)
	expect_args(t, lines[0], {"-F", "@CFG", "-p", "2222", "localhost", "grep needle"}, data_dir)
	// 2: the shell-action step: cd prepended, then /bin/bash -c '<env> <argv>'
	//    with 'some one' single-quoted
	expect_args(
		t,
		lines[1],
		{
			"-F",
			"@CFG",
			"-p",
			"2222",
			"localhost",
			"cd /work/dir && /bin/bash -c 'NAME='\\''some one'\\'' make greeter'",
		},
		data_dir,
	)
	// 3: scp put file: no -r; 4: scp put dir: -r; 5: scp get: -r
	expect_args(
		t,
		lines[2],
		{"-F", "@CFG", "-P", "2222", "@BASE/payload.txt", "localhost:up/there.txt"},
		data_dir,
	)
	expect_args(
		t,
		lines[3],
		{"-F", "@CFG", "-P", "2222", "-r", "@BASE/indir", "localhost:up/dir"},
		data_dir,
	)
	expect_args(
		t,
		lines[4],
		{"-F", "@CFG", "-P", "2222", "-r", "localhost:down/src.txt", "@BASE/got.txt"},
		data_dir,
	)
	testing.expect(
		t,
		len(lines) == 5,
		fmt.tprintf("expected exactly 5 invocations, got %d", len(lines)),
	)

	// -- generated ssh config -------------------------------------------------------
	cfg_path := fmt.tprintf("%s/targets/vm1/ssh.conf", data_dir)
	cfg, cerr := os.read_entire_file(cfg_path, context.temp_allocator)
	testing.expectf(t, cerr == nil, "config file must exist at %s", cfg_path)
	wants := [?]string {
		"HostName 192.0.2.1",
		"User root",
		"ControlMaster auto",
		"ControlPersist 10m",
		"IdentityFile ~/.k/id",
	}
	for want in wants {
		testing.expectf(
			t,
			strings.contains(string(cfg), want),
			"config missing '%s' in:\n%s",
			want,
			cfg,
		)
	}
	// ControlPath rewritten absolute, inside the target's own control dir
	ctl := fmt.tprintf("ControlPath %s/targets/vm1/ssh/ctl", data_dir)
	testing.expectf(t, strings.contains(string(cfg), ctl), "config missing '%s' in:\n%s", ctl, cfg)

	// -- non-zero exit is data for run; error for put; close lifecycle --------------
	posix.setenv("STUB_EXIT", "42", true)
	v2 := new(data_dir)
	defer close(v2)
	err2, ok2 := run_string(
		v2,
		`
		local tgt = makac.new_ssh_target("vm2", { host = "h", user = "u" })
		local res = tgt:run({"false"})
		assert(res.code == 42, res.code) -- data, not error
		local pok, perr = pcall(function() tgt:put("/tmp/x", "y") end)
		assert(not pok and tostring(perr):find("upload failed"), tostring(perr))
		local sok, serr = pcall(step, { uses = "shell", target = tgt,
			with = { cmd = {"false"} } })
		assert(not sok and tostring(serr):find("exited with code 42"), tostring(serr))
		local iok, ires = pcall(step, { uses = "shell", target = tgt,
			with = { cmd = {"false"}, ignore_exit_code = true } })
		assert(iok and ires and ires.err == nil and ires.out.code == 42, tostring(ires))
		-- close: idempotent; run/put/get fail after; ssh gets '-O exit'
		tgt:close(); tgt:close()
		local cok, cerr = pcall(function() tgt:run({"true"}) end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
		cok, cerr = pcall(function() tgt:put("a", "b") end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
	`,
	)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)

	// the vm2 close ran through the stub: a -O exit invocation for vm2 exists
	log2, _ := os.read_entire_file(log_path, context.temp_allocator)
	lines2 := strings.split(string(log2), "\n", context.temp_allocator)
	found_exit := false
	vm2_marker := "targets/vm2/ssh.conf"
	for ln in lines2 {
		if strings.contains(ln, vm2_marker) && strings.contains(ln, "<-O><exit>") {
			found_exit = true
		}
	}
	testing.expect(t, found_exit, string(log2))
}

// expect one stub-log line to hold exactly `want` args (as <arg> tokens),
// where "@CFG" expands to <data_dir>/targets/<any>/ssh.conf and "@BASE/..."
// to the test's base dir.
expect_args :: proc(t: ^testing.T, line: string, want: []string, data_dir: string) {
	// tokens: split on '><', strip the brackets
	parts := strings.split(line, "><", context.temp_allocator)
	if !testing.expectf(
		t,
		len(parts) == len(want),
		"expected %d args, got '%s'",
		len(want),
		line,
	) {return}
	for w, i in want {
		got := parts[i]
		got = strings.trim_prefix(got, "<")
		got = strings.trim_suffix(got, ">")
		exp := w
		if exp == "@CFG" {
			testing.expectf(
				t,
				strings.has_suffix(got, ".makac/targets/vm1/ssh.conf") ||
				strings.has_prefix(got, data_dir),
				"arg %d: expected generated config path, got '%s'",
				i,
				got,
			)
			continue
		}
		if strings.has_prefix(exp, "@BASE") {
			exp = strings.trim_prefix(exp, "@BASE")
			// caller passed base-relative; absolute check happens via suffix
			testing.expectf(
				t,
				strings.has_suffix(got, exp),
				"arg %d: expected suffix '%s', got '%s'",
				i,
				exp,
				got,
			)
			continue
		}
		testing.expectf(t, got == exp, "arg %d: expected '%s', got '%s'", i, exp, got)
	}
}

// new_ssh_target: construction writes config only (no live connection);
// argument validation errors are clear.
@(test)
test_ssh_target_construction :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_sshnew_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	v := new(dir)
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- defaults: port 22; name is the required positional argument
		local tgt = makac.new_ssh_target("a.b-c_d", { host = "h", user = "u" })
		assert(tgt.kind == "remote" and tgt.name == "a.b-c_d")
		tgt:close(); tgt:close() -- idempotent

		-- validation errors
		local cases = {
			{ nil, { host = "h", user = "u" }, "name" },
			{ "", { host = "h", user = "u" }, "name" },
			{ 42, { host = "h", user = "u" }, "name" },
			{ "n", nil, "spec must be a table" },
			{ "n", { user = "u" }, "host" },
			{ "n", { host = "h" }, "user" },
			{ "no/colon:ok", { host = "h", user = "u" }, "invalid name" },
			{ "n", { host = "h", user = "u", port = 70000 }, "port" },
		}
		for _, c in ipairs(cases) do
			local cok, cerr = pcall(makac.new_ssh_target, c[1], c[2])
			assert(not cok and tostring(cerr):find(c[3], 1, true),
				tostring(cerr) .. " ~ " .. c[3])
		end
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)

	// a data-dir-less VM must refuse ssh target creation with a clear error
	v2 := new()
	defer close(v2)
	err2, ok2 := run_string(
		v2,
		`
		local cok, cerr = pcall(makac.new_ssh_target, "n", { host = "h", user = "u" })
		assert(not cok and tostring(cerr):find("data directory"), tostring(cerr))
	`,
	)
	defer delete(err2.message)
	testing.expect(t, ok2, err2.message)
}

// Target wiring (task17): with.target resolution via makac.resolve_target,
// remote-run shell wrapping handed to the target's run op, finders getting
// the real target, makac.close_all_targets teardown via vm.call_named.
@(test)
test_target_wiring :: proc(t: ^T) {
	v := new()
	defer close(v)
	err, ok := run_string(
		v,
		`
		-- shell with an EXPLICIT host target works like the default
		local r = step { uses = "shell", with = { target = makac.host, cmd = {"echo", "hi"} } }
		assert(r.out.code == 0 and r.out.stdout == "hi\n")

		-- resolve_target: nil with/target -> host; explicit target passes through
		assert(makac.resolve_target(nil) == makac.host)
		assert(makac.resolve_target({}) == makac.host)
		assert(makac.resolve_target({ target = makac.host }) == makac.host)
		local bok, berr = pcall(makac.resolve_target, { target = {} })
		assert(not bok and tostring(berr):find("must be a target"), tostring(berr))

		-- mock remote target: finders must receive the REAL target and run
		-- their commands through target:run
		local seen_argv = nil
		local mock = makac.new_target {
			kind = "remote", name = "mock",
			run = function(argv, opts)
				seen_argv = argv
				return { code = 0, stdout = "MARK=1\n", stderr = "" }
			end,
			close = function() end,
		}
		assert(makac.is_target(mock) and mock.kind == "remote" and mock.name == "mock")
		makac.register_fact_finder("probe", function(target)
			return { hit = target:run({"env"}).stdout:find("MARK") ~= nil }
		end)
		local f = step { uses = "facts", with = { target = mock, finders = { probe = "probe" } } }
		assert(seen_argv and seen_argv[1] == "env", "finder must run via target:run")
		-- finder receives the REAL target (the wrapper incl. lifecycle), and
		-- its facts land under the namespace
		assert(f.out.facts.probe.hit == true)

		-- built-in env/os finders also take the target's run output
		local osmock = makac.new_target {
			kind = "remote", name = "osmock",
			run = function(argv)
				local cmd = table.concat(argv, " ")
				if cmd == "uname -s" then return { code = 0, stdout = "Plan9\n", stderr = "" } end
				if cmd == "uname -m" then return { code = 0, stdout = "transputer\n", stderr = "" } end
				return { code = 1, stdout = "", stderr = "?" }
			end,
		}
		local of = makac.run_action("facts", { target = osmock, finders = { sys = "os" } })
		assert(of.out.facts.sys.os == "plan9" and of.out.facts.sys.arch == "transputer")
		osmock:close()

		-- new_target: put/get absent -> clear "not supported" error; close
		-- absent -> tolerated, still idempotent
		local pok, perr = pcall(function() mock:put("a", "b") end)
		assert(not pok and tostring(perr):find("put") and tostring(perr):find("mock"), tostring(perr))

		-- close_all_targets: every registered target gets closed (host too:
		-- its close is a no-op)
		closed_marks = 0
		local c1 = makac.new_target { kind = "remote", name = "c1",
			run = function() return { code = 0, stdout = "", stderr = "" } end,
			close = function() closed_marks = closed_marks + 1 end }
		local c2 = makac.new_target { kind = "remote", name = "c2",
			run = function() return { code = 0, stdout = "", stderr = "" } end,
			close = function() error("boom") end } -- failing close tolerated
		makac.close_all_targets()
		assert(closed_marks == 1, closed_marks)
		assert(c1._closed and c2._closed)
	`,
	)
	defer delete(err.message)
	testing.expect(t, ok, err.message)
	// vm.call_named: missing path -> not called, no error; existing function
	// -> called; error inside -> surfaced
	v2 := new()
	defer close(v2)
	called, cerr := call_named(v2, "makac.does_not_exist")
	testing.expect(t, !called && cerr.message == "")
	called, cerr = call_named(v2, "makac.no.such.path")
	testing.expect(t, !called && cerr.message == "")
	e3, ok3 := run_string(
		v2,
		"function _boom() error('teardown went wrong') end mark_a=0 mark_b=0",
	)
	defer delete(e3.message)
	testing.expect(t, ok3, e3.message)
	called, cerr = call_named(v2, "_boom")
	if testing.expect(t, called) {
		testing.expect(t, strings.contains(cerr.message, "teardown went wrong"))
	}
	if cerr.message != "" {delete(cerr.message)}
	// a non-function value is NOT called
	e4, ok4 := run_string(v2, "makac._notafn = 42")
	defer delete(e4.message)
	testing.expect(t, ok4, e4.message)
	called, cerr = call_named(v2, "makac._notafn")
	testing.expect(t, !called && cerr.message == "")
}

// makac.listdir lists directory entries with name/is_dir and returns nil+err
// for a missing directory (the prelude relies on this for "not fetched yet").
@(test)
test_listdir :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_listdir_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	sub := strings.concatenate([]string{dir, "/sub"}, context.temp_allocator)
	testing.expect(t, os.make_directory(sub) == nil)
	fpath := strings.concatenate([]string{dir, "/f.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(fpath, "x") == nil)

	v := new()
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			`local es, err = makac.listdir("`,
			dir,
			`")
assert(err == nil)
assert(#es == 2, "expected 2 entries, got " .. #es)
local by_name = {}
for _, e in ipairs(es) do by_name[e.name] = e.is_dir end
assert(by_name["sub"] == true, "sub must be a dir")
assert(by_name["f.txt"] == false, "f.txt must be a file")
-- missing dir -> nil + error message (not a raised error)
local es2, err2 = makac.listdir("`,
			dir,
			`/no-such-dir")
assert(es2 == nil and type(err2) == "string")
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_listdir")
	if !ok {delete(err.message)}
	testing.expect(t, ok, "listdir semantics must hold in Lua")
}

// A VM with a data dir can load a package declared in packages.lua:
// makac.load_packages merges its exports under '<id>:<name>' keys and the
// pkgs: searcher makes its lib/ require-able.
@(test)
test_load_packages_and_pkgs_searcher :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_pkgs_*", context.allocator)
	testing.expect(t, derr == nil, "temp dir")
	defer os.remove_all(dir)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{dir, "/packages/demo/lib"}, context.temp_allocator),
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{dir, "/packages.lua"}, context.temp_allocator),
			`-- fetchgit entry; the fetch itself is not under test here, only loading
return { { id = "demo", fetcher = "fetchgit", with = { url = "unused" } } }`,
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate(
				[]string{dir, "/packages/demo/lib/util.lua"},
				context.temp_allocator,
			),
			`return { hello = function() return "pkg-lib-ok" end }`,
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{dir, "/packages/demo/makac.lua"}, context.temp_allocator),
			`return { actions = { thing = function(w) return { out = { did = "thing" } } end },
  fetchers = { fetchio = function(spec, dest) end } }`,
		) ==
		nil,
	)

	v := new(dir)
	defer close(v)
	err, ok := run_string(
		v,
		`
assert(makac.load_packages() == 1)
local util = require("pkgs:demo/util")
assert(util.hello() == "pkg-lib-ok")
local r = makac.run_action("demo:thing", nil)
assert(r.out.did == "thing")
assert(type(makac.registry.fetchers["demo:fetchio"]) == "function")
local ok2, err2 = pcall(require, "pkgs:demo/missing")
assert(not ok2 and err2:find("module 'pkgs:demo/missing' not found"), tostring(err2))
`,
		"test_load_packages",
	)
	if !ok {delete(err.message)}
	testing.expect(t, ok, "load_packages + pkgs: searcher must work in-VM")
}

// The built-in `filesystem` fetcher: a package lives at with.path and is
// loaded IN PLACE (its own directory, not .makac/packages/<id>). pkgs:
// requires resolve from the source path, so edits are picked up without any
// refetch step. Fetching only validates the path + makac.lua.
@(test)
test_filesystem_fetcher_in_place :: proc(t: ^T) {
	// the "data dir" (<dir>/.makac) and the dev package next to it
	root, rerr := os.make_directory_temp("", "makac_vm_fspkg_*", context.allocator)
	testing.expect(t, rerr == nil, "temp root")
	defer os.remove_all(root)
	defer delete(root, context.allocator)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{root, "/.makac"}, context.temp_allocator),
		) ==
		nil,
	)
	devpkg := strings.concatenate([]string{root, "/devpkg"}, context.temp_allocator)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{devpkg, "/lib"}, context.temp_allocator),
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{devpkg, "/lib/util.lua"}, context.temp_allocator),
			`return { VAL = "in-place-v1" }`,
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{devpkg, "/makac.lua"}, context.temp_allocator),
			`-- a package may require its own lib/ while loading
local util = require("pkgs:mypkg.dev/util")
return {
  actions = { dev_hello = function(w) return { out = { v = util.VAL } } end },
  -- packages may also contribute fetchers ('<id>:<name>'). This one just
  -- writes a marker file at <dest>/marker.txt so tests can observe it ran.
  fetchers = { devmark = function(spec, dest)
    local f = assert(io.open(dest .. "/marker.txt", "w"))
    f:write("fetched-by-mypkg.dev:devmark")
    f:close()
  end },
}`,
		) ==
		nil,
	)
	// where the in-chunk fetcher invocation writes its marker
	marker_dir := strings.concatenate([]string{root, "/fetchdest"}, context.temp_allocator)
	testing.expect(t, os.make_directory(marker_dir) == nil)
	// relative path: resolved against the project root (dir holding .makac)
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{root, "/.makac/packages.lua"}, context.temp_allocator),
			`return { { id = "mypkg.dev", fetcher = "filesystem", with = { path = "devpkg" } } }`,
		) ==
		nil,
	)

	data_dir := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)
	util_path := strings.concatenate([]string{devpkg, "/lib/util.lua"}, context.temp_allocator)
	v := new(data_dir)
	defer close(v)
	lua_src := strings.concatenate(
		[]string {
			// NOTE: NOT fmt.tprintf — Odin fmt eats Lua's {} table constructors!
			`
-- 'fetch' is pure validation for filesystem packages (nothing copied)
assert(makac.fetch_all() == 1)
-- package loads from the SOURCE path: makac.pkg_dirs points at devpkg
assert(makac.load_packages() == 1)
assert(makac.pkg_dirs["mypkg.dev"]:find("devpkg"), tostring(makac.pkg_dirs["mypkg.dev"]))
assert(not makac.pkg_dirs["mypkg.dev"]:find("/packages/"))
-- package-provided ACTION: via run_action and via step{}
local r = makac.run_action("mypkg.dev:dev_hello", nil)
assert(r.out.v == "in-place-v1", tostring(r.out.v))
local st = step { uses = "mypkg.dev:dev_hello", name = "fs step" }
assert(st.out.v == "in-place-v1")
-- package-provided LIBRARY code from the workflow side
local util = require("pkgs:mypkg.dev/util")
assert(util.VAL == "in-place-v1")
-- package-provided FETCHER: registered under '<id>:<name>' and callable
local f = makac.registry.fetchers["mypkg.dev:devmark"]
assert(type(f) == "function", "filesystem package's fetcher must be in the registry")
f({ id = "anything" }, "`,
			marker_dir,
			`") -- fetcher signature: (spec, dest)
local mf = assert(io.open("`,
			marker_dir,
			`/marker.txt", "r"))
assert(mf:read("a") == "fetched-by-mypkg.dev:devmark")
mf:close()
`,
		},
		context.temp_allocator,
	)
	err, ok := run_string(v, lua_src, "test_filesystem_fetcher_in_place")
	if !ok {fmt.eprintln(err.message); delete(err.message)}
	testing.expect(t, ok, "filesystem package must load in place")
	if !ok {return}

	// edit the lib module, fresh VM: the edit is live, no refetch
	testing.expect(
		t,
		os.write_entire_file_from_string(util_path, `return { VAL = "in-place-v2" }`) == nil,
	)
	v2 := new(data_dir)
	defer close(v2)
	err2, ok2 := run_string(
		v2,
		`
assert(makac.load_packages() == 1)
package.loaded["pkgs:mypkg.dev/util"] = nil
local util = require("pkgs:mypkg.dev/util")
assert(util.VAL == "in-place-v2", "edits must be picked up in place, got " .. tostring(util.VAL))
`,
		"test_filesystem_edit",
	)
	if !ok2 {delete(err2.message)}
	testing.expect(t, ok2, "edit must be picked up without refetching")

	// and the same holds with an ABSOLUTE with.path
	testing.expect(
		t,
		os.write_entire_file_from_string(
			strings.concatenate([]string{root, "/.makac/packages.lua"}, context.temp_allocator),
			strings.concatenate(
				[]string {
					`return { { id = "mypkg.dev", fetcher = "filesystem", with = { path = "`,
					devpkg,
					`" } } }`,
				},
				context.temp_allocator,
			),
		) ==
		nil,
	)
	v3 := new(data_dir)
	defer close(v3)
	err3, ok3 := run_string(
		v3,
		`
assert(makac.load_packages() == 1)
local r = makac.run_action("mypkg.dev:dev_hello", nil)
assert(r.out.v == "in-place-v2")
`,
		"test_filesystem_abs",
	)
	if !ok3 {delete(err3.message)}
	testing.expect(t, ok3, "absolute with.path must work")
}

// filesystem fetcher validation errors: missing path, missing with.path,
// and a listed-but-not-fetched fetchgit package all fail clearly.
@(test)
test_filesystem_fetcher_errors :: proc(t: ^T) {
	root, rerr := os.make_directory_temp("", "makac_vm_fspkgerr_*", context.allocator)
	testing.expect(t, rerr == nil, "temp root")
	defer os.remove_all(root)
	defer delete(root, context.allocator)
	testing.expect(
		t,
		os.make_directory_all(
			strings.concatenate([]string{root, "/.makac"}, context.temp_allocator),
		) ==
		nil,
	)

	write_pkgs := proc(root: string, body: string) {
		_ = os.write_entire_file_from_string(
			strings.concatenate([]string{root, "/.makac/packages.lua"}, context.temp_allocator),
			body,
		)
	}
	data_dir := strings.concatenate([]string{root, "/.makac"}, context.temp_allocator)

	// missing with.path
	write_pkgs(root, `return { { id = "bad", fetcher = "filesystem" } }`)
	v := new(data_dir)
	err, ok := run_string(
		v,
		`
local ok1, e1 = pcall(makac.load_packages)
assert(not ok1 and e1:find("with.path", 1, true), tostring(e1))
local ok2, e2 = pcall(makac.fetch_all)
assert(not ok2 and e2:find("with.path", 1, true), tostring(e2))
`,
		"missing with.path",
	)
	if !ok {delete(err.message)}
	testing.expect(t, ok, "missing with.path must error clearly")
	close(v)

	// path does not exist
	write_pkgs(
		root,
		`return { { id = "bad", fetcher = "filesystem", with = { path = "no-such-pkg" } } }`,
	)
	v2 := new(data_dir)
	err2, ok2 := run_string(
		v2,
		`
local ok1, e1 = pcall(makac.load_packages)
assert(not ok1 and e1:find("no-such-pkg", 1, true) and e1:find("not a directory", 1, true), tostring(e1))
local ok2, e2 = pcall(makac.fetch_all)
assert(not ok2 and e2:find("no-such-pkg", 1, true), tostring(e2))
`,
		"nonexistent path",
	)
	if !ok2 {fmt.eprintln(err2.message); delete(err2.message)}
	testing.expect(t, ok2, "nonexistent path must error clearly")
	close(v2)

	// listed but not fetched (non-filesystem): clear 'makac fetch' hint
	write_pkgs(
		root,
		`return { { id = "ghost", fetcher = "fetchgit", with = { url = "unused" } } }`,
	)
	v3 := new(data_dir)
	err3, ok3 := run_string(
		v3,
		`
local ok1, e1 = pcall(makac.load_packages)
assert(not ok1 and e1:find("ghost", 1, true) and e1:find("makac fetch", 1, true), tostring(e1))
`,
		"not fetched",
	)
	if !ok3 {delete(err3.message)}
	testing.expect(t, ok3, "not-yet-fetched package must tell the user to fetch")
	close(v3)
}

// makac.ssh_open session objects: method dispatch, introspection fields,
// lifecycle (idempotent close, closed-session refusals), __gc safety, and
// removal of the old integer-handle API. No stub ssh here (PATH env mutation
// would race test_ssh_target, which owns the stubbing): this test drives only
// paths that never invoke ssh except the one best-effort `ssh -O exit` from
// close(), which fails fast against the bogus host and is ignored by design.
// Actual command/transfer behavior over sessions is covered end-to-end by
// test_ssh_target (via makac.new_ssh_target).
@(test)
test_ssh_session_object :: proc(t: ^T) {
	base, derr := os.make_directory_temp("", "makac_vm_sshobj_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(base)
	defer delete(base, context.allocator)
	data_dir := fmt.tprintf("%s/.makac", base)
	testing.expect(t, os.make_directory(data_dir) == nil)

	v := new(data_dir)
	err, ok := run_string(
		v,
		`
		local sess = assert(makac.ssh_open("obj", {
			host = "h", user = "u", port = 2223,
		}))
		-- introspection + identity
		assert(sess.name == "obj" and sess.port == 2223)
		assert(tostring(sess):find("makac.ssh", 1, true), tostring(sess))
		assert(tostring(sess):find("obj", 1, true))

		-- methods exist and type-check self (calling without ':' errors)
		assert(type(sess.run) == "function" and type(sess.put) == "function"
			and type(sess.get) == "function" and type(sess.close) == "function")
		local sok, serr = pcall(function() return sess.run("echo") end)
		assert(not sok, "method call without self must fail")
		local pok, perr = pcall(function() return sess:missing_method() end)
		assert(not pok, "unknown method must fail")

		-- the old integer-handle API is gone
		assert(makac.ssh_run == nil and makac.ssh_put == nil
			and makac.ssh_get == nil and makac.ssh_close == nil
			and makac.ssh_target_new == nil, "flat ssh_* API must be removed")

		-- lifecycle: idempotent close; closed session refuses operations
		sess:close(); sess:close()
		local cok, cerr = pcall(function() sess:run("x") end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
		cok, cerr = pcall(function() sess:put("a", "b") end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
		assert(tostring(sess):find("closed", 1, true))

		-- a never-closed session collected by the GC: __gc frees memory only
		local leaked = makac.ssh_open("leaked", { host = "h", user = "u" })
		leaked = nil
		collectgarbage("collect")
	`,
	)
	// __gc for `leaked` runs at latest when the VM closes — must not crash
	close(v)
	testing.expect(t, ok, err.message)
	if !ok {delete(err.message)}
	if !ok {return}

	// config was generated for the named session's state dir
	cfg := fmt.tprintf("%s/targets/obj/ssh.conf", data_dir)
	testing.expectf(t, os.exists(cfg), "config must exist at %s", cfg)
}

// ---------------------------------------------------------------------------
// Fake QMP server (in-process): one unix-socket connection, line JSON,
// responds to the commands the qmp-binding test drives. Hermetic stand-in for
// qmp_test/fake_qmp.py so `odin test vm` needs no external processes.
// ---------------------------------------------------------------------------

Fake_QMP :: struct {
	ln: posix.FD,
	th: ^thread.Thread,
}

_fake_qmp_write :: proc "c" (conn: posix.FD, s: string) {
	off := 0
	for off < len(s) {
		n := posix.write(conn, raw_data(s[off:]), uint(int(len(s)) - off))
		if n <= 0 {return}
		off += int(n)
	}
}

_fake_qmp_respond :: proc "c" (conn: posix.FD, cmd: string) {
	context = runtime.default_context()
	out: string
	switch {
	case strings.contains(cmd, "qmp_capabilities"):
		out = `{"return":{}}`
	case strings.contains(cmd, "query-status"):
		_fake_qmp_write(
			conn,
			`{"event":"RTC_CHANGE","data":{"offset":1},"timestamp":{"seconds":1,"microseconds":2}}` +
			"\n",
		)
		_fake_qmp_write(conn, `{"event":"SPICE_INITIALIZED","data":{}}` + "\n")
		out = `{"return":{"status":"running","running":true}}`
	case strings.contains(cmd, "query-block"):
		// emit an event DURING this command so the multi-command batch test
		// can assert per-call event-buffer discipline (events from cmd 1
		// must survive cmd 2)
		_fake_qmp_write(
			conn,
			`{"event":"BLOCK_IO_ERROR","data":{"device":"drive0"}}` + "\n",
		)
		out = `{"return":[{"device":"drive0","type":"unknown"}]}`
	case strings.contains(cmd, "bad-cmd"):
		out = `{"error":{"class":"CommandNotFound","desc":"The command bad-cmd has not been found"}}`
	case strings.contains(cmd, "emit-later"):
		_fake_qmp_write(conn, `{"return":{}}` + "\n")
		time.sleep(60 * time.Millisecond)
		_fake_qmp_write(
			conn,
			`{"event":"RESET","data":{"guest":true},"timestamp":{"seconds":3,"microseconds":4}}` +
			"\n",
		)
		_fake_qmp_write(conn, `{"event":"SHUTDOWN","data":{"guest":false}}` + "\n")
		return
	case strings.contains(cmd, "hang"):
		return // never reply (exercises send timeout)
	case:
		out = `{"return":{}}`
	}
	_fake_qmp_write(conn, out)
	_fake_qmp_write(conn, "\n")
}

_fake_qmp_serve :: proc(srv: ^Fake_QMP) {
	context = runtime.default_context()
	// a closed client must surface EPIPE, not kill the process (vm.new does
	// this too, but the server thread may outlive/underlie any single VM)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	for {
		conn := posix.accept(srv.ln, nil, nil)
		if conn == -1 {return} 	// listener shut down: we're done
		_fake_qmp_handle(conn)
	}
}

_fake_qmp_handle :: proc(conn: posix.FD) {
	defer posix.close(conn)
	_fake_qmp_write(
		conn,
		`{"QMP":{"version":{"qemu":{"major":8,"minor":0,"micro":0},"package":"fake"},"capabilities":[]}}` +
		"\n",
	)
	buf: [64 * 1024]u8
	pending := 0
	for {
		n := posix.read(conn, &buf[pending], uint(len(buf) - pending))
		if n <= 0 {break}
		pending += int(n)
		for {
			idx := -1
			for i in 0 ..< pending {
				if buf[i] == '\n' {idx = i; break}
			}
			if idx < 0 {break}
			_fake_qmp_respond(conn, string(buf[:idx]))
			copy(buf[:], buf[idx + 1:pending])
			pending -= idx + 1
		}
	}
}

_fake_qmp_start :: proc(t: ^T, sock_path: string) -> ^Fake_QMP {
	srv := new_clone(Fake_QMP{}, context.temp_allocator)
	srv.ln = posix.socket(.UNIX, .STREAM, .IP)
	testing.expect(t, srv.ln != -1, "fake qmp: socket")
	addr: posix.sockaddr_un
	when ODIN_OS != .Linux {
		addr.sun_len = u8(size_of(posix.sockaddr_un))
	}
	addr.sun_family = .UNIX
	testing.expect(t, len(sock_path) < len(addr.sun_path), "socket path too long")
	for i in 0 ..< len(sock_path) {
		addr.sun_path[i] = sock_path[i]
	}
	testing.expect(
		t,
		posix.bind(srv.ln, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .OK,
		"fake qmp: bind",
	)
	testing.expect(t, posix.listen(srv.ln, 1) == .OK, "fake qmp: listen")
	srv.th = thread.create_and_start_with_poly_data(srv, _fake_qmp_serve)
	return srv
}

_fake_qmp_stop :: proc(srv: ^Fake_QMP) {
	posix.shutdown(srv.ln, .RDWR) // unblock a pending accept
	thread.join(srv.th)
	thread.destroy(srv.th)
	posix.close(srv.ln)
}

// makac.qmp_open client objects over a fake in-process QMP server: connect +
// handshake, send (decoded replies, QMP errors as data, multi-command order,
// arguments marshaling, transport timeout raises), the event-buffer discipline
// (poll reports whether it drained anything, drained events stay buffered,
// events(n) reads the first n buffered; consume drops the n oldest and raises
// on over-consumption), lifecycle and validation.
@(test)
test_qmp_binding :: proc(t: ^T) {
	dir, derr := os.make_directory_temp("", "makac_vm_qmp_*", context.allocator)
	testing.expectf(t, derr == nil, "make temp dir: {}", derr)
	defer os.remove_all(dir)
	defer delete(dir, context.allocator)

	sock := fmt.tprintf("%s/qmp.sock", dir)
	srv := _fake_qmp_start(t, sock)

	v := new()
	lua_chunk := `
		local q = assert(makac.qmp_open("@SOCK@"))
		assert(tostring(q):find("makac.qmp", 1, true))

		-- send: reply payload decoded (integers stay integers)
		local res = q:send({ { execute = "query-status" } })
		assert(#res == 1, #res)
		assert(res[1].error == nil)
		assert(res[1]["return"].status == "running")
		assert(res[1]["return"].running == true)

		-- the events drained DURING that send are buffered; poll reports
		-- nothing new, events() reads what the send buffered
		local fresh = q:poll()
		assert(fresh == false, "poll reports only freshly drained events")
		local sent_evs = q:events()
		assert(#sent_evs == 2, #sent_evs)
		assert(sent_evs[1].name == "RTC_CHANGE" and sent_evs[2].name == "SPICE_INITIALIZED")

		-- a QMP error reply is data, not a raised error
		local bad = q:send({ { execute = "bad-cmd" } })
		assert(bad[1].error ~= nil and bad[1].error.class == "CommandNotFound")
		assert(bad[1].error.desc:find("bad%-cmd"), bad[1].error.desc)
		assert(bad[1]["return"] == nil)

		-- multiple commands run in order; results align; arguments marshal
		-- (nesting, arrays, dashed keys) without complaint
		local two = q:send({
			{ execute = "query-block" },
			{ execute = "anything", arguments = { id = "x", n = 3,
				list = { 1, 2 }, sub = { ["node-name"] = "b" } } },
		})
		assert(#two == 2, #two)
		assert(two[1]["return"][1].device == "drive0")
		assert(two[2]["return"] ~= nil and two[2].error == nil)

		-- per-call event-buffer discipline: the BLOCK_IO_ERROR emitted by the
		-- fake server during query-block must still be buffered when q:send
		-- returns, even though the second command ran after it (would be
		-- wiped by per-command semantics)
		local batch_evs = q:events()
		assert(#batch_evs == 1, #batch_evs)
		assert(batch_evs[1].name == "BLOCK_IO_ERROR")
		assert(batch_evs[1].data.device == "drive0")
		q:consume(1)
		assert(#q:events() == 0)

		-- poll: drain events arriving AFTER the reply; they stay buffered
		q:send({ { execute = "emit-later" } })
		assert(q:poll({ timeout_s = 0.4 }) == true, "poll reports drained events")
		local evs = q:events()
		assert(#evs == 2, #evs)
		assert(evs[1].name == "RESET" and evs[1].data.guest == true)
		assert(evs[1].timestamp.seconds == 3) -- integer, not float
		assert(evs[2].name == "SHUTDOWN")

		-- events(n): reads the first n only, buffer unchanged
		local first = q:events(1)
		assert(#first == 1 and first[1].name == "RESET")
		assert(#q:events() == 2, "events(n) does not consume")
		assert(#q:events(0) == 0)
		local rok, rerr = pcall(function() q:events(3) end)
		assert(not rok and tostring(rerr):find("cannot read"), tostring(rerr))

		q:consume(2)
		assert(#q:events() == 0)
		local ook, oerr = pcall(function() q:consume(1) end)
		assert(not ook and tostring(oerr):find("cannot consume"), tostring(oerr))
		q:consume(0) -- no-op

		-- send validation
		local vok, verr = pcall(function() q:send({}) end)
		assert(not vok and tostring(verr):find("at least one"), tostring(verr))
		vok, verr = pcall(function() q:send({ { arguments = {} } }) end)
		assert(not vok and tostring(verr):find("execute"), tostring(verr))
		vok, verr = pcall(function()
			q:send({ { execute = "x", arguments = { f = print } } })
		end)
		assert(not vok and tostring(verr):find("cannot be encoded"), tostring(verr))

		-- methods type-check self
		local sok, serr = pcall(function() return q.send({}) end)
		assert(not sok, "method call without self must fail")

		-- a hung VM surfaces as a raised timeout
		local tok, terr = pcall(function()
			q:send({ { execute = "hang" } }, { timeout_s = 0.2 })
		end)
		assert(not tok and tostring(terr):find("timed out"), tostring(terr))

		-- close: idempotent; methods refuse afterwards
		q:close(); q:close()
		local cok, cerr = pcall(function() q:send({ { execute = "query-status" } }) end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
		cok, cerr = pcall(function() q:poll() end)
		assert(not cok and tostring(cerr):find("closed"), tostring(cerr))
		assert(tostring(q):find("closed", 1, true))

		-- constructor validation
		local ok1, e1 = pcall(makac.qmp_open, "@DIR@/no-such.sock")
		assert(not ok1 and tostring(e1):find("connect"), tostring(e1))
		local ok2, e2 = pcall(makac.qmp_open, {})
		assert(not ok2 and tostring(e2):find("socket"), tostring(e2))
		local ok3, e3 = pcall(makac.qmp_open, { socket = "a", tcp = "b" })
		assert(not ok3 and tostring(e3):find("not both"), tostring(e3))

		-- a client collected without close(): __gc closes it (no crash)
		local leaked = makac.qmp_open("@SOCK@")
		leaked = nil
		collectgarbage("collect")
	`
	chunk1, _ := strings.replace_all(lua_chunk, "@SOCK@", sock, context.temp_allocator)
	chunk2, _ := strings.replace_all(chunk1, "@DIR@", dir, context.temp_allocator)
	err, ok := run_string(v, chunk2)
	close(v) // runs pending __gc finalizers; must not crash
	_fake_qmp_stop(srv)
	if !ok {delete(err.message)}
	testing.expect(t, ok, err.message)
}
