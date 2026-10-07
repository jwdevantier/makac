-- cases/steps.lua — step semantics: immediate execution, ordering, reporting
-- (stderr-only, statuses, colors), failure aborts the workflow.
-- Contracts: site/src/concepts/steps.md, reference/step.md.

local h = require("harness")

h.suite("steps")

h.case("steps", "steps_run_in_evaluation_order_and_later_steps_see_results", function(ctx)
	ctx.write("order.lua", [[
local a = step {
  uses = "shell",
  with = { cmd = { "printf", "first" } },
}
print("A:" .. a.out.stdout)
step {
  uses = "shell",
  with = { cmd = { "printf", a.out.stdout .. "-second" } },
}
]])
	local r = ctx.run({ "run", "order.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	-- immediate execution: A's result is available to later Lua before B runs
	h.contains(r.stdout, "A:first", "first step result visible as a Lua value")
end)

h.case("steps", "failure_aborts_before_later_steps", function(ctx)
	ctx.write("abort.lua", [[
local r1 = step { uses = "shell", with = { cmd = { "printf", "reached-1" } } }
print(r1.out.stdout)
step { uses = "shell", with = { cmd = { "false" } } }
step { uses = "shell", with = { cmd = { "printf", "unreachable" } } }
]])
	local r = ctx.run({ "run", "abort.lua" })
	h.eq(r.code, 1, "exit code")
	h.contains(r.stdout, "reached-1", "first step ran")
	h.not_contains(r.stdout, "unreachable", "step after the failure never ran")
end)

h.case("steps", "control_flow_decides_which_steps_run", function(ctx)
	ctx.write("loop.lua", [[
for i = 1, 3 do
  local r = step { uses = "shell", with = { cmd = { "printf", "iter-" .. i } } }
  print(r.out.stdout)
end
if false then
  step { uses = "shell", with = { cmd = { "printf", "never" } } }
end
]])
	local r = ctx.run({ "run", "loop.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "iter-1", "loop iteration 1")
	h.contains(r.stdout, "iter-2", "loop iteration 2")
	h.contains(r.stdout, "iter-3", "loop iteration 3")
	h.not_contains(r.stdout, "never", "conditional branch not taken")
end)

h.case("steps", "progress_goes_to_stderr_only", function(ctx)
	ctx.write("io.lua", [[
print("workflow-output")
step { name = "io-check", uses = "shell", with = { cmd = { "true" } } }
]])
	local r = ctx.run({ "run", "io.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.eq(r.stdout, "workflow-output\n", "stdout carries only the workflow's output")
	h.matches(r.stderr, "run: %[host%] io%-check", "start report on stderr")
	h.matches(h.norm(ctx, r.stderr), "changed: %[host%] io%-check %(Ts%)", "end report on stderr")
end)

h.case("steps", "step_name_defaults_to_action_default", function(ctx)
	-- docs: name defaults to the action's registered default_name; 'shell'
	-- registers the default name "run shell command".
	ctx.write("noname.lua", [[
step { uses = "shell", with = { cmd = { "true" } } }
]])
	local r = ctx.run({ "run", "noname.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.matches(r.stderr, "run: %[host%] run shell command", "name falls back to the action default")
end)

h.case("steps", "colors_off_with_makac_color_never", function(ctx)
	-- ctx.run already sets MAKAC_COLOR=never
	ctx.write("c.lua", 'step { uses = "shell", with = { cmd = { "true" } } }')
	local r = ctx.run({ "run", "c.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.not_contains(r.stderr, "\27", "no ANSI escapes when colors are off")
end)

h.case("steps", "colors_on_with_makac_color_always", function(ctx)
	ctx.write("c.lua", 'step { uses = "shell", with = { cmd = { "true" } } }')
	local r = ctx.run({ "run", "c.lua" }, {
		env = { MAKAC_COLOR = "always", TERM = "dumb" },
	})
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stderr, "\27", "ANSI escapes when forced on, even with TERM=dumb")
end)
