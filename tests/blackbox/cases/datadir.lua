-- cases/datadir.lua — data-directory resolution: the walk-up rule, the .git
-- auto-create, and behavior outside any project.
-- Contracts: site/src/concepts/project-directory.md, reference/cli.md.

local h = require("harness")

h.suite("datadir")

local pdir_lua = [[
print("PROJECT_DIR: " .. tostring(PROJECT_DIR))
]]

h.case("datadir", "walkup_finds_dotmakac_from_subdir", function(ctx)
	ctx.mkdir_p("proj/.makac")
	ctx.mkdir_p("proj/sub/deep")
	ctx.write("proj/pdir.lua", pdir_lua)
	local r = ctx.run({ "run", ctx.path("proj/pdir.lua") }, { chdir = ctx.path("proj/sub/deep") })
	h.eq(r.code, 0, "exit code")
	h.contains(r.stdout, "PROJECT_DIR: " .. ctx.path("proj"), "project root resolved by walking up")
end)

h.case("datadir", "git_dir_triggers_datadir_creation", function(ctx)
	ctx.mkdir_p("repo/.git")
	ctx.mkdir_p("repo/sub")
	ctx.write("repo/pdir.lua", pdir_lua)
	local r = ctx.run({ "run", ctx.path("repo/pdir.lua") }, { chdir = ctx.path("repo/sub") })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.truthy(ctx.exists("repo/.makac"), ".makac created beside .git")
	h.truthy(ctx.exists("repo/makac_project.lua"), "empty project file created too")
end)

h.case("datadir", "fetch_outside_project_errors_with_advice", function(ctx)
	-- tmp has no .makac/.git anywhere above (it lives under /tmp)
	ctx.mkdir_p("nowhere")
	local r = ctx.run({ "fetch" }, { chdir = ctx.path("nowhere") })
	h.eq(r.code, 1, "exit code")
	h.contains(r.stderr, "makac init", "advice to init a data directory")
end)

h.case("datadir", "run_outside_project_still_works", function(ctx)
	ctx.mkdir_p("nowhere")
	ctx.write("nowhere/pdir.lua", pdir_lua)
	local r = ctx.run({ "run", "pdir.lua" }, { chdir = ctx.path("nowhere") })
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "PROJECT_DIR: nil", "project-less run: PROJECT_DIR is nil")
end)
