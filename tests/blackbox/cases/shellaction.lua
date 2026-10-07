-- cases/shellaction.lua — the built-in `shell` action, full with/out matrix.
-- Contracts: site/src/reference/actions.md ("shell"), concepts/actions.md.
--
-- NOTE the model: the action CAPTURES output (out.stdout/out.stderr
-- separately); a non-zero exit code is DATA (out.code) that ALSO fails the
-- step unless with.ignore_exit_code. Commands run directly — no shell
-- interpolation on the host.

local h = require("harness")

h.suite("shell")

-- Runs a one-workflow whose `body` must produce output on stdout; body has
-- access to nothing but the makac API. Returns the run result {code, ...}.
local function workflow(ctx, body)
	ctx.write("w.lua", body)
	return ctx.run({ "run", "w.lua" })
end

h.case("shell", "captures_stdout_stderr_code_separately", function(ctx)
	local r = workflow(ctx, [[
local res = step {
  uses = "shell",
  with = { cmd = { "sh", "-c", "printf out-part; printf err-part >&2; exit 3" },
           ignore_exit_code = true },
}
print("code:   " .. res.out.code)
print("stdout: " .. res.out.stdout)
print("stderr: " .. res.out.stderr)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "code:   3", "exit code is data")
	h.contains(r.stdout, "stdout: out-part", "stdout captured separately")
	h.contains(r.stdout, "stderr: err-part", "stderr captured separately")
end)

h.case("shell", "default_exit_code_policy_fails_step", function(ctx)
	local r = workflow(ctx, [[
step { uses = "shell", with = { cmd = { "sh", "-c", "exit 7" } } }
print("unreachable")
]])
	h.eq(r.code, 1, "non-zero exit fails the step by default")
	h.not_contains(r.stdout, "unreachable", "workflow aborted")
	h.matches(r.stderr, "failed: %[host%]", "failed status reported")
end)

h.case("shell", "ignore_exit_code_continues", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell", with = { cmd = { "sh", "-c", "exit 7" },
                   ignore_exit_code = true } }
print("err is set: " .. tostring(res.err ~= nil))
print("continued")
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "err is set: false", "failure-as-data sets no err")
	h.contains(r.stdout, "continued", "workflow continued")
end)

h.case("shell", "no_shell_interpolation_on_host", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell", with = { cmd = { "printf", "%s", "$HOME ~ *" } } }
print(res.out.stdout)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "$HOME ~ *", "argv words are literal; no shell expansion")
end)

h.case("shell", "env_option_sets_variables", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell",
                   with = { cmd = { "printenv", "BLACKBOX_FOO" },
                            env = { BLACKBOX_FOO = "via-env-opt" } } }
print(res.out.stdout)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "via-env-opt", "with.env reached the command")
end)

h.case("shell", "env_prefix_via_argv_like_nvme_check", function(ctx)
	-- the nvme-check style: env assignments as leading argv words through
	-- the env(1) binary, e.g. makac.exec({"env", "KEY=" .. v, prog})
	local r = workflow(ctx, [[
local res = step { uses = "shell",
                   with = { cmd = { "env", "BLACKBOX_BAR=via-argv", "printenv", "BLACKBOX_BAR" } } }
print(res.out.stdout)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "via-argv", "env-prefix argv style works")
end)

h.case("shell", "chdir_sets_working_directory", function(ctx)
	ctx.mkdir_p("sub/dir")
	local r = workflow(ctx, ([[
local res = step { uses = "shell", with = { cmd = { "sh", "-c", "pwd" },
                   chdir = %q } }
print(res.out.stdout)
]]):format(ctx.path("sub/dir")))
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, ctx.path("sub/dir"), "command ran in chdir")
end)

h.case("shell", "stdin_is_fed_to_the_command", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell",
                   with = { cmd = { "cat" }, stdin = "hello-stdin" } }
print(res.out.stdout)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "hello-stdin", "stdin data reached the command")
end)

h.case("shell", "join_merges_stderr_into_stdout", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell",
                   with = { cmd = { "sh", "-c", "printf out; printf err >&2" },
                            join = true } }
print("stdout: " .. res.out.stdout)
print("stderr empty: " .. tostring(res.out.stderr == ""))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "stdout: outerr", "true interleaving in stdout")
	h.contains(r.stdout, "stderr empty: true", "stderr comes back empty when joined")
end)

h.case("shell", "on_line_streams_lines_and_keeps_full_capture", function(ctx)
	local r = workflow(ctx, [[
local seen = {}
local res = step { uses = "shell",
                   with = { cmd = { "printf", "a\nb\nc\n" },
                            on_line = function(line, stream)
                              seen[#seen + 1] = stream .. ":" .. line
                            end } }
print("lines:  " .. table.concat(seen, ","))
print("stdout: " .. res.out.stdout:gsub("\n", "|"))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "lines:  stdout:a,stdout:b,stdout:c", "callback got complete lines in order")
	h.contains(r.stdout, "stdout: a|b|c|", "full capture still returned")
end)

h.case("shell", "timeout_kills_and_sets_timed_out", function(ctx)
	local r = workflow(ctx, [[
local t0 = makac.time.now()
local res = step { uses = "shell",
                   with = { cmd = { "sleep", "30" }, timeout_s = 0.5,
                            ignore_exit_code = true } }
print("timed_out: " .. tostring(res.out.timed_out))
print("elapsed_s: " .. tostring((makac.time.now() - t0) / makac.time.ns_per_s < 10))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "timed_out: true", "killed by timeout_s")
	h.contains(r.stdout, "elapsed_s: true", "killed quickly, did not run 30s")
end)

h.case("shell", "missing_program_fails_the_step", function(ctx)
	local r = workflow(ctx, [[
step { uses = "shell", with = { cmd = { "definitely-not-a-real-program-xyz" } } }
]])
	h.eq(r.code, 1, "spawn failure fails the step")
	h.matches(r.stderr, "failed: %[host%]", "failed status reported")
	h.contains(r.stderr, "definitely-not-a-real-program-xyz", "error names the program")
end)

h.case("shell", "out_table_shape_is_normalized", function(ctx)
	local r = workflow(ctx, [[
local res = step { uses = "shell", with = { cmd = { "true" } } }
print("changed: " .. tostring(res.changed))
print("skipped: " .. tostring(res.skipped))
print("err:     " .. tostring(res.err))
print("has out: " .. tostring(type(res.out) == "table"))
print("output:  " .. tostring(type(res.out.output) == "string"))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "changed: true", "shell always reports changed")
	h.contains(r.stdout, "skipped: false", "not skipped")
	h.contains(r.stdout, "err:     nil", "no err on success")
	h.contains(r.stdout, "has out: true", "out table present")
	h.contains(r.stdout, "output:  true", "out.output (joined) present")
end)
