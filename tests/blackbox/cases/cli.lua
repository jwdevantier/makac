-- cases/cli.lua — CLI surface: --version, usage, init, run (explicit/implied/
-- shebang), failure exit codes, script globals (arg, SCRIPT_DIR, PROJECT_DIR).
-- Contracts: site/src/reference/cli.md.

local h = require("harness")

h.suite("cli")

h.case("cli", "version", function(ctx)
	local r = ctx.run({ "--version" })
	h.eq(r.code, 0, "exit code")
	h.matches(r.stdout, "^%d+%.%d+\n?$", "version format (major.minor)")
end)

h.case("cli", "no_args_prints_usage", function(ctx)
	local r = ctx.run({})
	h.eq(r.code, 1, "exit code")
	h.contains(r.stderr, "usage: makac", "usage on stderr")
end)

h.case("cli", "init_creates_datadir_and_project_file", function(ctx)
	-- run init from a *different* directory so cwd does not matter
	local proj = ctx.path("proj")
	local r = ctx.run({ "init", proj })
	h.eq(r.code, 0, "exit code")
	h.contains(r.stdout, "initialized data directory", "confirmation on stdout")
	h.truthy(ctx.exists("proj/.makac"), ".makac created")
	h.truthy(ctx.exists("proj/makac_project.lua"), "makac_project.lua created")
end)

h.case("cli", "init_dotmakac_path_used_verbatim", function(ctx)
	local r = ctx.run({ "init", ctx.path("weird.makac") })
	h.eq(r.code, 0, "exit code")
	h.truthy(ctx.exists("weird.makac"), "path used verbatim, no /.makac appended")
	h.truthy(ctx.exists("makac_project.lua"), "project file created beside it")
end)

h.case("cli", "init_is_idempotent", function(ctx)
	local proj = ctx.path("proj")
	h.eq(ctx.run({ "init", proj }).code, 0, "first init")
	h.eq(ctx.run({ "init", proj }).code, 0, "second init is not an error")
	h.truthy(ctx.exists("proj/.makac"), ".makac still there")
end)

-- NOTE: the shell action CAPTURES command output into out.stdout/out.stderr;
-- it does not stream to makac's stdout. A workflow prints captured output
-- itself when it wants it there.
local hello_lua = [[
local res = step {
  name = "smoke",
  uses = "shell",
  with = { cmd = { "echo", "makac-blackbox-ok" } },
}
print(res.out.stdout)
]]

h.case("cli", "run_executes_step", function(ctx)
	ctx.write("hello.lua", hello_lua)
	local r = ctx.run({ "run", "hello.lua" })
	h.eq(r.code, 0, "exit code")
	h.contains(r.stdout, "makac-blackbox-ok", "captured output printed by the workflow")
	-- progress goes to stderr; shell steps always report 'changed'
	h.matches(r.stderr, "run: %[host%] smoke", "start report on stderr")
	h.matches(h.norm(ctx, r.stderr), "changed: %[host%] smoke %(Ts%)", "end report with status+timing")
end)

h.case("cli", "run_word_is_optional", function(ctx)
	ctx.write("hello.lua", hello_lua)
	local r = ctx.run({ "hello.lua" })
	h.eq(r.code, 0, "exit code")
	h.contains(r.stdout, "makac-blackbox-ok", "workflow ran")
end)

h.case("cli", "failing_step_aborts_with_error", function(ctx)
	ctx.write("doom.lua", [[
step {
  name = "doomed",
  uses = "shell",
  with = { cmd = { "false" } },
}
]])
	local r = ctx.run({ "run", "doom.lua" })
	h.eq(r.code, 1, "exit code")
	h.matches(r.stderr, "failed: %[host%] doomed", "failed status reported")
	h.contains(r.stderr, "step 'doomed' (uses 'shell') failed", "error names step and action")
end)

h.case("cli", "script_context_globals", function(ctx)
	ctx.write("echo_args.lua", [[
print("script:   " .. tostring(arg and arg[0]))
print("nargs:    " .. tostring(arg and #arg or 0))
for i = 1, #(arg or {}) do
  print(("  [%d] %q"):format(i, arg[i]))
end
print("SCRIPT_DIR:  " .. tostring(SCRIPT_DIR))
print("PROJECT_DIR: " .. tostring(PROJECT_DIR))
]])
	local r = ctx.run({ "run", "echo_args.lua", "one", "two words", "--flag" })
	h.eq(r.code, 0, "exit code")
	h.contains(r.stdout, "script:   echo_args.lua", "arg[0] is the path as given")
	h.contains(r.stdout, "nargs:    3", "arg count")
	h.contains(r.stdout, '[1] "one"', "arg[1]")
	h.contains(r.stdout, '[2] "two words"', "spaces preserved verbatim")
	h.contains(r.stdout, '[3] "--flag"', "dashes preserved verbatim")
	h.contains(r.stdout, "SCRIPT_DIR:  " .. ctx.tmp, "SCRIPT_DIR is the script's directory")
	h.contains(r.stdout, "PROJECT_DIR: nil", "no project here -> PROJECT_DIR is nil")
end)

h.case("cli", "shebang_script_executes", function(ctx)
	-- kernel resolves env-makac via PATH; stage the binary under test behind
	-- a tmp 'makac' name and prepend it to PATH for a faithful shebang test.
	ctx.mkdir_p("bin")
	makac.fs.symlink(ctx.bin, ctx.path("bin/makac"))
	ctx.write("hello.lua", '#!/usr/bin/env makac\nprint("shebang-ok")\n')
	local r0 = makac.exec({ "chmod", "+x", ctx.path("hello.lua") })
	h.eq(r0.code, 0, "chmod")
	local r = makac.exec({ ctx.path("hello.lua") }, {
		chdir = ctx.tmp,
		env = {
			MAKAC_COLOR = "never",
			PATH = ctx.path("bin") .. ":" .. (os.getenv("PATH") or ""),
		},
	})
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "shebang-ok", "script ran under makac")
end)
