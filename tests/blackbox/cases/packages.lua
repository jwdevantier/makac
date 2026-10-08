-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/packages.lua — the package/fetch machinery end to end, hermetically:
-- filesystem + fetchgit (against LOCAL git repos) fetchers, content-addressed
-- storage + prune, the fetch worklist with package-provided fetchers,
-- requires wiring checks, doctor output, editor stub generation.
-- Contracts: site/src/concepts/packages.md, reference/fetchers.md,
-- reference/doctor.md. Message shapes probed on the reference binary.
-- (fetchurl/download live in the download tier per docs/test-strategy.md.)

local h = require("harness")

h.suite("packages")

-- --- fixture helpers ----------------------------------------------------------

--- Create <tmp>/<name>/{.makac, makac_project.lua}; return the project path.
local function project(ctx, name, project_lua)
	h.eq(ctx.run({ "init", ctx.path(name) }).code, 0, "init " .. name)
	ctx.write(name .. "/makac_project.lua", project_lua)
	return ctx.path(name)
end

--- Write a file, creating missing parent dirs first.
local function writef(ctx, path, body)
	makac.fs.mkdir_p((ctx.path(path):gsub("/[^/]*$", "")))
	makac.fs.write_file(ctx.path(path), body)
end

--- Write a plain package dir INSIDE the given project dir (filesystem
--- with.path resolves against the project ROOT, per docs — probed).
local function pkg(ctx, proj_rel, manifest, files)
	writef(ctx, proj_rel .. "/makac_package.lua", manifest)
	for rel, body in pairs(files or {}) do
		writef(ctx, proj_rel .. "/" .. rel, body)
	end
end

--- Create a LOCAL git repo at <tmp>/<path> containing the given files,
--- commit everything, return the commit hash. Needs git on PATH (doctor's
--- own base check); the case fails loudly if git is absent.
local function git_pkg(ctx, path, files, msg)
	ctx.mkdir_p(path)
	for rel, body in pairs(files) do
		writef(ctx, path .. "/" .. rel, body)
	end
	local d = ctx.path(path)
	h.eq(makac.exec({ "git", "init", "-q", "-b", "main", d }).code, 0, "git init")
	h.eq(makac.exec({ "git", "add", "-A" }, { chdir = d }).code, 0, "git add")
	local c = makac.exec(
		{ "git", "-c", "user.email=bb@bb", "-c", "user.name=bb", "commit", "-qm", msg or "c" },
		{ chdir = d })
	h.eq(c.code, 0, "git commit: " .. c.stderr)
	local rev = makac.exec({ "git", "rev-parse", "HEAD" }, { chdir = d })
	h.eq(rev.code, 0, "git rev-parse")
	return (rev.stdout:gsub("%s+$", ""))
end

--- List the single-level entries of <proj>/.makac/packages (names).
local function package_keys(proj)
	local entries = assert(makac.fs.listdir(proj .. "/.makac/packages"))
	local names = {}
	for _, e in ipairs(entries) do names[#names + 1] = e.name end
	table.sort(names)
	return names
end

local PKG_MANIFEST = [[
return { actions = { hello = function() return { out = { v = %q } } end } }
]]

-- --- cases --------------------------------------------------------------------

h.case("packages", "fetch_filesystem_in_place", function(ctx)
	pkg(ctx, "proj/pk", ([[return { actions = { hi = function() return { out = { v = "fs-pkg" } } end } }]]))
	local proj = project(ctx, "proj", [[
return {
  inputs = { src = { fetcher = "filesystem", with = { path = "pk" } } },
  packages = { pk = "src" },
}
]])
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 0, "fetch exit: " .. f.stderr)
	h.contains(f.stdout, "fetching src via filesystem", "fetch report")
	h.contains(f.stdout, "in place (nothing copied)", "in-place note")
	ctx.write("proj/w.lua", [[
local r = step { uses = "pk:hi", with = {} }
print("got: " .. r.out.v)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "got: fs-pkg", "package action ran")
end)

h.case("packages", "filesystem_works_even_without_fetch", function(ctx)
	-- probed quirk: in-place (filesystem) packages load directly from
	-- with.path; the wired-but-not-fetched guard applies to STORED packages.
	pkg(ctx, "proj/pk", ("return { actions = { hi = function() return { out = { v = \"nofetch\" } } end } }"))
	local proj = project(ctx, "proj", [[
return {
  inputs = { src = { fetcher = "filesystem", with = { path = "pk" } } },
  packages = { pk = "src" },
}
]])
	ctx.write("proj/w.lua", [[
local r = step { uses = "pk:hi", with = {} }
print("got: " .. r.out.v)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "got: nofetch", "filesystem package loads without fetch")
end)

h.case("packages", "filesystem_missing_manifest_fails_fetch", function(ctx)
	ctx.mkdir_p("proj/empty-dir") -- no makac_package.lua inside
	local proj = project(ctx, "proj", [[
return {
  inputs = { src = { fetcher = "filesystem", with = { path = "empty-dir" } } },
  packages = { pk = "src" },
}
]])
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 1, "fetch must fail (typo'd paths caught at fetch, docs)")
	h.contains(f.stderr, "makac_package.lua", "error names the manifest")
end)

h.case("packages", "fetchgit_local_repo_cycle", function(ctx)
	local rev = git_pkg(ctx, "repo", {
		["makac_package.lua"] = PKG_MANIFEST:format("git-v1"),
		["lib/util.lua"] = 'return { FROM = "lib-via-pkgs" }',
	})
	local proj = project(ctx, "proj", ([[
return {
  inputs = { repo = { fetcher = "fetchgit", with = { url = %q, rev = %q } } },
  packages = { g = "repo" },
}
]]):format(ctx.path("repo"), rev))
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 0, "fetch exit: " .. f.stderr)
	h.contains(f.stdout, "fetching repo via fetchgit", "fetch report")
	h.eq(#package_keys(proj), 1, "one content-addressed package stored")
	h.matches(package_keys(proj)[1], "^fetchgit%-%x+$", "key = fetcher + hash")
	ctx.write("proj/w.lua", [[
local r = step { uses = "g:hello", with = {} }
print("action: " .. r.out.v)
print("lib:    " .. require("pkgs/g/util").FROM)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "action: git-v1", "stored package's action ran")
	h.contains(r.stdout, "lib:    lib-via-pkgs", "pkgs/<alias>/... require works")
end)

h.case("packages", "fetchgit_rev_change_rekeys_and_prunes", function(ctx)
	local rev1 = git_pkg(ctx, "repo", {
		["makac_package.lua"] = PKG_MANIFEST:format("git-v1"),
	}, "v1")
	local proj = project(ctx, "proj", ([[
return {
  inputs = { repo = { fetcher = "fetchgit", with = { url = %q, rev = %q } } },
  packages = { g = "repo" },
}
]]):format(ctx.path("repo"), rev1))
	h.eq(ctx.run({ "fetch" }, { chdir = proj }).code, 0, "first fetch")
	local first_key = package_keys(proj)[1]
	-- new commit; rewire the SAME label to the new rev
	makac.fs.write_file(ctx.path("repo/makac_package.lua"), PKG_MANIFEST:format("git-v2"))
	h.eq(makac.exec({ "git", "add", "-A" }, { chdir = ctx.path("repo") }).code, 0, "git add v2")
	local c = makac.exec(
		{ "git", "-c", "user.email=bb@bb", "-c", "user.name=bb", "commit", "-qm", "v2" },
		{ chdir = ctx.path("repo") })
	h.eq(c.code, 0, "git commit v2")
	local rev2 = (makac.exec({ "git", "rev-parse", "HEAD" }, { chdir = ctx.path("repo") }).stdout:gsub("%s+$", ""))
	ctx.write("proj/makac_project.lua", ([[
return {
  inputs = { repo = { fetcher = "fetchgit", with = { url = %q, rev = %q } } },
  packages = { g = "repo" },
}
]]):format(ctx.path("repo"), rev2))
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 0, "second fetch: " .. f.stderr)
	local keys = package_keys(proj)
	h.eq(#keys, 1, "stale entry pruned; exactly one stored package")
	h.truthy(keys[1] ~= first_key, "new content key for new rev")
	ctx.write("proj/w.lua", [[
local r = step { uses = "g:hello", with = {} }
print("action: " .. r.out.v)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "action: git-v2", "new code served")
end)

h.case("packages", "wired_but_never_fetched_aborts_run_with_advice", function(ctx)
	local rev = git_pkg(ctx, "repo", { ["makac_package.lua"] = PKG_MANIFEST:format("x") })
	local proj = project(ctx, "proj", ([[
return {
  inputs = { repo = { fetcher = "fetchgit", with = { url = %q, rev = %q } } },
  packages = { g = "repo" },
}
]]):format(ctx.path("repo"), rev))
	ctx.write("proj/w.lua", 'print("should not run")\n')
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 1, "stored-but-missing package aborts the run")
	h.contains(r.stderr, "never fetched", "explains the situation")
	h.contains(r.stderr, "run 'makac fetch' first", "advice")
	h.not_contains(r.stdout, "should not run", "workflow never executed")
end)

h.case("packages", "unknown_fetcher_fails_fetch_naming_waiter", function(ctx)
	pkg(ctx, "proj/pk", "return {}")
	local proj = project(ctx, "proj", [[
return {
  inputs = {
    a = { fetcher = "filesystem", with = { path = "pk" } },
    b = { fetcher = "nosuchfetcher", with = {} },
  },
  packages = { a = "a", b = "b" },
}
]])
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 1, "fetch aborts")
	h.contains(f.stderr, "failed to make progress", "worklist no-progress error")
	h.contains(f.stderr, "'b'", "names the stuck input")
	h.contains(f.stderr, "nosuchfetcher", "names the missing fetcher")
end)

h.case("packages", "package_provided_fetcher_worklist", function(ctx)
	-- port of makac/e2e_test/package-fetchers.sh: provider used in place
	-- exports fetcher 'synth'; consumer input (listed BEFORE its provider)
	-- uses 'foo:synth'. The worklist must fetch foo, register its fetchers,
	-- then fetch bar.
	pkg(ctx, "proj/foo", [[
return {
  fetchers = {
    synth = {
      key = function(w)
        return "synth-" .. makac.sha256("synth\0" .. tostring(w.tag)):sub(1, 16)
      end,
      fetch = function(spec, dest)
        makac.fs.mkdir_p(dest)
        makac.fs.write_file(dest .. "/makac_package.lua",
          ("return { actions = { hello = function() return { out = { v = %q } } end } }")
            :format(tostring(spec.with.tag)))
      end,
    },
  },
}
]])
	local proj = project(ctx, "proj", [[
return {
  inputs = {
    bar = { fetcher = "foo:synth", with = { tag = "bar-ok" } },
    foo = { fetcher = "filesystem", with = { path = "foo" } },
  },
  packages = { foo = "foo", bar = "bar" },
}
]])
	local f = ctx.run({ "fetch" }, { chdir = proj })
	h.eq(f.code, 0, "fetch exit: " .. f.stderr)
	h.contains(f.stdout, "fetching bar via foo:synth", "consumer fetched THROUGH the provider's fetcher")
	local keys = package_keys(proj)
	h.eq(#keys, 1, "only the consumer is stored (provider is in place)")
	h.matches(keys[1], "^synth%-%x+$", "stored under the provider fetcher's key")
	ctx.write("proj/w.lua", [[
local r = makac.run_action("bar:hello", {})
print("synth: " .. r.out.v)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "synth: bar-ok", "synthesized package loaded and ran")
end)

h.case("packages", "requires_not_wired_aborts_run_with_author_message", function(ctx)
	pkg(ctx, "proj/depender", 'return { requires = { dep = "DEP needs wiring, see docs" } }')
	local proj = project(ctx, "proj", [[
return {
  inputs = { d = { fetcher = "filesystem", with = { path = "depender" } } },
  packages = { depender = "d" },
}
]])
	ctx.write("proj/w.lua", 'print("should not run")\n')
	local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
	h.eq(r.code, 1, "run stops at the first missing requires")
	h.contains(r.stderr, "requires 'dep', which is not wired", "names the missing alias")
	h.contains(r.stderr, "DEP needs wiring, see docs", "quotes the package author's message")
	h.not_contains(r.stdout, "should not run", "workflow never executed")
end)

h.case("packages", "doctor_groups_requires_and_exit_codes", function(ctx)
	pkg(ctx, "proj/depender", 'return { requires = { dep = "DEP needs wiring, see docs" } }')
	pkg(ctx, "proj/plain", "return {}")
	local proj = project(ctx, "proj", [[
return {
  inputs = {
	 d = { fetcher = "filesystem", with = { path = "depender" } },
	 p = { fetcher = "filesystem", with = { path = "plain" } },
  },
  packages = { depender = "d", plain = "p" },
}
]])
	local bad = ctx.run({ "doctor" }, { chdir = proj })
	h.eq(bad.code, 1, "doctor exits 1 on any ERROR")
	h.contains(bad.stdout, "== makac ==", "base group first")
	h.contains(bad.stdout, "== depender ==", "package group present")
	h.contains(bad.stdout, "== depender ==  1 error", "error count in group header")
	h.contains(bad.stdout, "ERROR requires 'dep', which is not wired", "requires ERROR reported")
	h.contains(bad.stdout, "ADVICE", "advice lines")
	h.contains(bad.stdout, "no health checks implemented", "packages without health.lua note it")
	-- named groups only
	local named = ctx.run({ "doctor", "plain" }, { chdir = proj })
	h.eq(named.code, 0, "named group without errors exits 0")
	h.contains(named.stdout, "== plain ==", "only the named group")
	h.not_contains(named.stdout, "== depender ==", "unnamed group omitted")
	local ghost = ctx.run({ "doctor", "ghost" }, { chdir = proj })
	h.eq(ghost.code, 1, "unknown group exits 1")
	h.contains(ghost.stderr, "unknown group", "unknown group reported")
end)

h.case("packages", "doctor_unfetched_package_advises_fetch", function(ctx)
	-- probed: a package whose code can't be loaded reports an ERROR
	-- 'package is not fetched' with the fetch advice.
	local proj = project(ctx, "proj", [[
return {
  inputs = { gone = { fetcher = "filesystem", with = { path = "nowhere" } } },
  packages = { gone = "gone" },
}
]])
	-- 'nowhere' does not exist under the project root: unloadable
	local r = ctx.run({ "doctor" }, { chdir = proj })
	h.eq(r.code, 1, "not-fetched package is an ERROR")
	h.contains(r.stdout, "== gone ==", "package group present")
	h.contains(r.stdout, "package is not fetched", "not-fetched ERROR")
	h.contains(r.stdout, "run `makac fetch`", "advice")
end)

h.case("packages", "fetch_without_project_file_is_informational", function(ctx)
	h.eq(ctx.run({ "init", ctx.path("proj") }).code, 0, "init")
	makac.exec({ "rm", ctx.path("proj/makac_project.lua") })
	local f = ctx.run({ "fetch" }, { chdir = ctx.path("proj") })
	h.eq(f.code, 0, "not an error")
	h.contains(f.stdout, "no makac_project.lua found", "informational message")
	h.contains(f.stdout, ctx.path("proj/makac_project.lua"), "points at the file's location")
end)

h.case("packages", "init_generates_editor_stubs", function(ctx)
	h.eq(ctx.run({ "init", ctx.path("proj") }).code, 0, "init")
	local stub = makac.fs.read_file(ctx.path("proj/.makac/makac.lua"))
	h.truthy(stub ~= nil, ".makac/makac.lua generated")
	h.contains(stub, "---@class Makac", "contains the LuaCATS API stub")
	h.truthy(ctx.exists("proj/.makac/pkgs"), "pkgs/ alias dir generated")
end)

h.case("packages", "package_loading_works_from_project_subdirs", function(ctx)
	local rev = git_pkg(ctx, "repo", { ["makac_package.lua"] = PKG_MANIFEST:format("deep") })
	local proj = project(ctx, "proj", ([[
return {
  inputs = { repo = { fetcher = "fetchgit", with = { url = %q, rev = %q } } },
  packages = { g = "repo" },
}
]]):format(ctx.path("repo"), rev))
	h.eq(ctx.run({ "fetch" }, { chdir = proj }).code, 0, "fetch")
	ctx.mkdir_p("proj/sub/deep")
	ctx.write("proj/sub/deep/w.lua", [[
local r = step { uses = "g:hello", with = {} }
print("deep: " .. r.out.v)
]])
	local r = ctx.run({ "run", "w.lua" }, { chdir = ctx.path("proj/sub/deep") })
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "deep: deep", "packages loaded via walk-up from a subdir")
end)
