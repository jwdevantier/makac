-- specs/exec_spawn.lua — makac.exec / makac.spawn / makac.pid_alive in-VM.
-- Contracts: site/src/lua-api/makac-api.md. Deeper than the black-box
-- 'shell' suite: argument validation and exact result shapes.

local api = require("api")

api.group("exec")

api.t("exec", "argv_validation", function()
	api.raises(function() makac.exec({}) end, "argv must not be empty", "empty argv raises")
	-- NOTE: docs say 'argv must be an array of strings'; the reference impl
	-- COERCES non-strings (exec({"printf", 5}) prints "5") — see findings.md.
	-- We encode only the documented surface here.
end)

api.t("exec", "result_shape_and_separate_capture", function()
	local r = makac.exec({ "sh", "-c", "printf o; printf e >&2; exit 5" })
	api.eq(r.code, 5, "exit code is data")
	api.eq(r.stdout, "o", "stdout separate")
	api.eq(r.stderr, "e", "stderr separate")
	api.eq(r.timed_out, false, "timed_out present and false")
end)

api.t("exec", "chdir_env_stdin_combined", function()
	local d = api.dir("exec-x")
	local r = makac.exec({ "sh", "-c", "pwd; printenv BB_X; cat" }, {
		chdir = d,
		env = { BB_X = "ex" },
		stdin = "piped",
	})
	api.eq(r.code, 0, "exit code")
	api.eq(r.stdout, d .. "\nex\npiped", "chdir + env + stdin all applied")
	-- NOTE: the typestub's RunOpts names this field 'cwd?' — wrong; the real,
	-- documented (site docs) and honored field is 'chdir' (findings.md).
end)

api.t("exec", "join_merges_stderr_with_true_interleaving", function()
	local r = makac.exec({ "sh", "-c", "printf out; printf err >&2" }, { join = true })
	api.eq(r.stdout, "outerr", "interleaved into stdout")
	api.eq(r.stderr, "", "stderr empty when joined")
end)

api.t("exec", "on_line_complete_lines_and_abort", function()
	local seen = {}
	local r = makac.exec({ "printf", "a\nb\nc\n" }, {
		on_line = function(line, stream) seen[#seen + 1] = stream .. ":" .. line end,
	})
	api.eq(table.concat(seen, ","), "stdout:a,stdout:b,stdout:c", "complete lines in order")
	api.eq(r.stdout, "a\nb\nc\n", "full capture alongside streaming")
	-- a raising callback aborts the command (and raises)
	api.raises(function()
		makac.exec({ "printf", "x\ny\n" }, { on_line = function() error("stop", 0) end })
	end, "stop", "raising on_line aborts")
end)

api.t("exec", "timeout_kills_and_reports", function()
	local t0 = makac.time.now()
	local r = makac.exec({ "sleep", "30" }, { timeout_s = 0.5 })
	api.eq(r.timed_out, true, "timed_out set")
	api.truthy((makac.time.now() - t0) < 10 * makac.time.ns_per_s, "killed quickly")
end)

api.t("exec", "spawn_failure_raises", function()
	api.raises(function() makac.exec({ "bb-no-such-program" }) end,
		nil, "missing program raises (not data)")
end)

api.group("spawn")

api.t("spawn", "stdout_and_stderr_paths_required", function()
	api.raises(function() makac.spawn({ "true" }, {}) end,
		"opts.stdout", "missing stdout raises")
	api.raises(function() makac.spawn({ "true" }, { stdout = "/tmp/x" }) end,
		"stderr", "missing stderr raises")
end)

api.t("spawn", "detached_child_to_files_and_reaping", function()
	local d = api.dir("spawn-x")
	-- stdin is /dev/null: 'cat' must get EOF immediately and exit cleanly
	local proc = makac.spawn({ "sh", "-c", "cat > " .. d .. "/collected" }, {
		stdout = d .. "/out",
		stderr = d .. "/err",
	})
	api.type_is(proc.pid, "number", "proc.pid is an integer")
	api.eq(makac.pid_alive(proc.pid), true, "alive while running")
	local st = proc:status()
	api.truthy(st == "running" or type(st) == "table", "status() shape")
	while proc:status() == "running" do makac.time.sleep(20 * makac.time.ns_per_ms) end
	api.eq(proc:status().code, 0, "reaped exit code (cached thereafter)")
	api.eq(makac.fs.read_file(d .. "/collected"), "", "stdin was /dev/null (EOF)")
	api.eq(makac.pid_alive(proc.pid), false, "pid released after reap")
end)

api.t("spawn", "pid_alive_for_bogus_pid_is_false", function()
	api.eq(makac.pid_alive(4194303), false, "kill(pid,0) ESRCH -> false, never raises")
end)
