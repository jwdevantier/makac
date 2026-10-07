-- specs/surface.lua — presence meta-test: every documented API name exists
-- with the promised Lua type. Catches whole missing registrations at a
-- glance (especially valuable while the Zig port registers incrementally).
--
-- Inventory = union of the typestub (makac/luals/makac.lua), the Lua-API
-- docs (site/src/lua-api/*.md) and the prelude's exported functions.
-- KNOWN STUB GAPS (impl has them; stub omits them — see docs/findings.md):
-- is_target, make_target, new_target, resolve_target, defer, errdefer,
-- define_action, normalize_result, register_fetcher, register_fact_finder,
-- project_file_path, resolve_fetcher.

local api = require("api")

api.group("surface")

local EXPECTED = {
	-- host primitives (baked in from the host language)
	["makac.exec"] = "function",
	["makac.spawn"] = "function",
	["makac.pid_alive"] = "function",
	["makac.random_hex"] = "function",
	["makac.download"] = "function",
	["makac.qmp_open"] = "function",
	["makac.sha256"] = "function",
	["makac.listdir"] = "function", -- flat alias of makac.fs.listdir
	["makac.data_dir"] = "string",
	["makac._luals_stub"] = "string",
	["makac._luals_setup"] = "function",
	["makac._ssh_open"] = "function",
	["makac._shquote"] = "function",
	["makac.project_root"] = "function", -- host-side (takes over where Lua can't)
	-- fs
	["makac.fs.sep"] = "string",
	["makac.fs.path"] = "function",
	["makac.fs.path_join"] = "function",
	["makac.fs.null_file"] = "function",
	["makac.fs.cwd"] = "function",
	["makac.fs.open_dir"] = "function",
	["makac.fs.listdir"] = "function",
	["makac.fs.mkdir_p"] = "function",
	["makac.fs.read_file"] = "function",
	["makac.fs.write_file"] = "function",
	["makac.fs.stat"] = "function",
	["makac.fs.mktemp_dir"] = "function",
	["makac.fs.mktemp_file"] = "function",
	["makac.fs.sha256"] = "function",
	["makac.fs.symlink"] = "function",
	-- time / env / json
	["makac.time.now"] = "function",
	["makac.time.sleep"] = "function",
	["makac.time.ns_per_us"] = "number",
	["makac.time.ns_per_ms"] = "number",
	["makac.time.ns_per_s"] = "number",
	["makac.env.all"] = "function",
	["makac.env.version"] = "function",
	["makac.env.makac_path"] = "function",
	["makac.json.dumps"] = "function",
	["makac.json.loads"] = "function",
	-- prelude: scoped cleanup
	["makac.defer"] = "function",
	["makac.errdefer"] = "function",
	-- prelude: registries
	["makac.define_action"] = "function",
	["makac.run_action"] = "function",
	["makac.normalize_result"] = "function",
	["makac.register_fetcher"] = "function",
	["makac.register_fact_finder"] = "function",
	["makac.registry"] = "table",
	-- prelude: targets
	["makac.host"] = "table",
	["makac.is_target"] = "function",
	["makac.resolve_target"] = "function",
	["makac.make_target"] = "function",
	["makac.new_target"] = "function",
	["makac.new_ssh_target"] = "function",
	["makac.close_all_targets"] = "function",
	-- prelude: package machinery
	["makac.project_file_path"] = "function",
	["makac.pkg_dirs"] = "table",
	["makac.read_project_file"] = "function",
	["makac.resolve_fetcher"] = "function",
	["makac.resolve_pkg_dir"] = "function",
	["makac.fetch_all"] = "function",
	["makac.load_packages"] = "function",
	["makac.package_info"] = "function",
	-- globals
	["step"] = "function",
	["arg"] = "table",
	["SCRIPT_DIR"] = "string",
}

local function lookup(path)
	local cur = _G
	for part in path:gmatch("[^%.]+") do
		if type(cur) ~= "table" then return nil end
		cur = cur[part]
	end
	return cur
end

api.t("surface", "every_documented_name_exists_with_its_type", function()
	local missing = {}
	for path, wanttype in pairs(EXPECTED) do
		local v = lookup(path)
		if v == nil then
			missing[#missing + 1] = path .. " (absent)"
		elseif type(v) ~= wanttype then
			missing[#missing + 1] = path .. " (type " .. type(v) .. ", want " .. wanttype .. ")"
		end
	end
	api.eq(table.concat(missing, "\n"), "", "surface inventory complete")
end)

api.t("surface", "listdir_flat_alias_is_fs_listdir", function()
	api.eq(makac.listdir, makac.fs.listdir, "makac.listdir aliases makac.fs.listdir")
end)

api.t("surface", "script_context_globals", function()
	api.type_is(arg, "table", "arg is a table while a workflow runs")
	api.matches(arg[0], "run%.lua$", "arg[0] is the workflow path as given")
	-- docs: SCRIPT_DIR is ABSOLUTE; arg[0] may be relative (as given)
	api.eq(SCRIPT_DIR:sub(1, 1), "/", "SCRIPT_DIR is absolute")
	api.matches(SCRIPT_DIR, "/tests/api$", "SCRIPT_DIR is the workflow's directory")
	-- PROJECT_DIR may be nil (project-less) or a string (run inside a project)
	local t = type(PROJECT_DIR)
	api.truthy(t == "nil" or t == "string", "PROJECT_DIR is nil or string, got " .. t)
end)
