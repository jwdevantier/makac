-- specs/project.lua — the package/project machinery against an in-tmp
-- fixture project: read_project_file, project_root/project_file_path,
-- resolve_fetcher/resolve_pkg_dir, load_packages, package_info, pkg_dirs,
-- and the require searchers (pkgs/<alias>/... and package-local ./...).
-- Contracts: site/src/concepts/packages.md, lua-api/workflow-dsl.md.
--
-- Heavy fetch scenarios (worklist, pruning, fetchgit) stay in the blackbox
-- 'packages' suite; here we use the filesystem fetcher (in-place, hermetic).

local api = require("api")

api.group("project")

-- build the fixture: <root>/proj/{.makac, makac_project.lua, pkgsrc/...}
local function build_fixture()
	local proj = api.dir("proj")
	api.dir("proj/.makac")
	api.dir("proj/pkgsrc/lib")
	makac.fs.write_file(proj .. "/pkgsrc/makac_package.lua", [[
local util = require("./util")
return {
  actions = {
    hello = function(with)
      return { out = { greeting = "hello from pkg, util=" .. util.UTIL } }
    end,
  },
}
]])
	makac.fs.write_file(proj .. "/pkgsrc/lib/util.lua", [[
return { UTIL = "util-value" }
]])
	makac.fs.write_file(proj .. "/makac_project.lua", [[
return {
  inputs = {
    src = { fetcher = "filesystem", with = { path = "pkgsrc" } },
  },
  packages = { testpkg = "src" },
}
]])
	return proj
end

api.t("project", "read_project_file_and_paths", function()
	local proj = build_fixture()
	local dd = proj .. "/.makac"
	api.eq(makac.project_root(dd), proj, "project_root from data dir")
	api.eq(makac.project_file_path(dd), proj .. "/makac_project.lua", "project file path")
	local inputs, aliases, labels = makac.read_project_file(dd)
	api.eq(inputs.src.fetcher, "filesystem", "inputs keyed by label")
	-- probed: 'aliases' is an ARRAY of wiring records {alias=, label=}, not a map
	api.eq(aliases[1].alias, "testpkg", "wiring record: alias")
	api.eq(aliases[1].label, "src", "wiring record: label")
	local found = false
	for _, l in ipairs(labels) do if l == "src" then found = true end end
	api.truthy(found, "labels list contains the label")
end)

api.t("project", "resolve_pkg_dir_filesystem_resolves_against_project_root", function()
	local proj = build_fixture()
	local dd = proj .. "/.makac"
	local inputs = makac.read_project_file(dd)
	local dir = makac.resolve_pkg_dir(inputs.src, dd)
	api.eq(dir, proj .. "/pkgsrc", "relative with.path resolved against project root")
end)

api.t("project", "load_packages_registers_actions_and_require", function()
	local proj = build_fixture()
	local dd = proj .. "/.makac"
	local n = makac.load_packages(dd)
	api.eq(n, 1, "one package loaded")
	local info = makac.package_info("testpkg")
	api.type_is(info, "table", "package_info after load")
	local res = makac.run_action("testpkg:hello")
	api.eq(res.out.greeting, "hello from pkg, util=util-value",
		"action callable; its package-local require('./util') resolved")
	-- and the lib is require-able by consumers under the alias
	local util = require("pkgs/testpkg/util")
	api.eq(util.UTIL, "util-value", "pkgs/<alias/...> searcher works")
end)

api.t("project", "package_info_unknown_alias_is_nil", function()
	api.eq(makac.package_info("no-such-alias-apitest"), nil, "nil, not an error")
end)

api.t("project", "resolve_fetcher_builtin_and_inline", function()
	-- docs: 'Resolves an entry's fetcher to its fetch callable' — probed: the
	-- returned value is a bare FUNCTION in both cases, not the fetcher object.
	local f = makac.resolve_fetcher({ fetcher = "filesystem" })
	api.type_is(f, "function", "built-in by name -> fetch callable")
	-- docs: an entry's 'fetcher' value may BE an inline { fetch=, key= } object
	local inl = makac.resolve_fetcher({
		fetcher = {
			fetch = function(spec, dest) end,
			key = function(w) return "k" end,
		},
	})
	api.type_is(inl, "function", "inline object contributes its fetch as function")
	api.raises(function()
		makac.resolve_fetcher({ fetcher = "ghost-fetcher" })
	end, nil, "unknown fetcher name raises")
end)
