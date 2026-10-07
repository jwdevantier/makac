-- cases/facts.lua — the built-in `facts` action and fact finders.
-- Contracts: site/src/concepts/facts.md, reference/actions.md ("facts").

local h = require("harness")

h.suite("facts")

h.case("facts", "builtin_finders_populate_namespaces", function(ctx)
	ctx.write("w.lua", [[
local res = step {
  uses = "facts",
  with = { finders = { os = "os", env = "env" } },
}
print("os:    " .. tostring(res.out.facts.os.os))
print("arch:  " .. tostring(res.out.facts.os.arch))
print("env:   " .. tostring(type(res.out.facts.env) == "table"))
print("HOME?  " .. tostring(res.out.facts.env.HOME ~= nil))
]])
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "os:    linux", "os finder reports the OS")
	h.matches(r.stdout, "arch:  %S+", "os finder reports an arch")
	h.contains(r.stdout, "env:   true", "env finder returns a table")
	h.contains(r.stdout, "HOME?  true", "env table contains the environment")
end)

h.case("facts", "custom_function_finder", function(ctx)
	ctx.write("w.lua", [[
local res = step {
  uses = "facts",
  with = {
    finders = {
      mine = function(target)
        local r = target:run({ "printf", "finder-ran" })
        return { greeting = r.stdout:gsub("%s+$", "") }
      end,
    },
  },
}
print("custom: " .. res.out.facts.mine.greeting)
]])
	h.eq(ctx.run({ "run", "w.lua" }).code, 0)
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "custom: finder-ran", "function finder ran and its table landed in the namespace")
end)

h.case("facts", "arbitrary_namespace_names", function(ctx)
	ctx.write("w.lua", [[
local res = step { uses = "facts", with = { finders = { whatever = "os" } } }
print("wired under 'whatever': " .. tostring(res.out.facts.whatever.os))
]])
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "wired under 'whatever': linux", "namespace key is caller-chosen")
end)

h.case("facts", "gathering_never_reports_changed", function(ctx)
	ctx.write("w.lua", [[
local res = step { uses = "facts", with = { finders = { os = "os" } } }
print("changed: " .. tostring(res.changed))
]])
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "changed: false", "facts action never changes state")
	h.matches(h.norm(ctx, r.stderr), "ok: %[host%] gather facts", "status is 'ok', not 'changed'")
end)

h.case("facts", "finder_returning_non_table_fails", function(ctx)
	ctx.write("w.lua", [[
step { uses = "facts", with = { finders = { bad = function(t) return 42 end } } }
]])
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 1, "non-table finder result fails the step")
	h.matches(r.stderr, "failed: %[host%]", "failed status reported")
end)

h.case("facts", "raising_finder_fails", function(ctx)
	ctx.write("w.lua", [[
step { uses = "facts", with = { finders = { bad = function(t) error("boom", 0) end } } }
]])
	local r = ctx.run({ "run", "w.lua" })
	h.eq(r.code, 1, "raising finder fails the step")
	h.contains(r.stderr, "boom", "the finder's error surfaces")
end)
