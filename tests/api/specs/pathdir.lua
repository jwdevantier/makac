-- specs/pathdir.lua — the `path` value and `Dir` handle userdata types.
-- Contracts: site/src/lua-api/makac-api.md + typestub classes Path/Dir.
-- Edge values (basename("/") == "", etc.) were pinned by probing the
-- reference binary and are marked.

local api = require("api")

api.group("pathdir")

api.t("pathdir", "path_is_a_value_not_a_string", function()
	local p = makac.fs.path("/tmp/x.txt")
	api.neq(type(p), "string", "path is userdata, not a bare string")
	api.eq(tostring(p), "/tmp/x.txt", "tostring yields the string")
	-- fs functions accept strings AND paths; path-returning fns hand back paths
	-- NOTE probed: path values compare by IDENTITY (no __eq): two paths from the
	-- same string are not ==; compare via tostring() (findings.md).
	api.eq(tostring(makac.fs.path(p)), "/tmp/x.txt", "path() of a path yields the same string")
	local joined = makac.fs.path_join("/a", "b", "", "c")
	api.eq(tostring(joined), "/a/b/c", "path_join drops empty elements")
end)

api.t("pathdir", "dirname_basename_edges", function()
	local p = makac.fs.path
	-- NOTE probed ASYMMETRY: basename() returns a STRING, dirname() returns a
	-- path VALUE (userdata); both concat/tostring cleanly (findings.md).
	api.type_is(p("/a/b/c.txt"):basename(), "string", "basename returns a string")
	api.neq(type(p("/a/b/c.txt"):dirname()), "string", "dirname returns a path value")
	api.eq(p("/a/b/c.txt"):basename(), "c.txt", "basename basic")
	api.eq(tostring(p("/a/b/c.txt"):dirname()), "/a/b", "dirname basic")
	api.eq(p("foo/"):basename(), "foo", "trailing slash tolerated (probed)")
	api.eq(tostring(p("/"):dirname()), "/", "dirname of root is root (probed)")
	api.eq(p("/"):basename(), "", "basename of root is empty (probed)")
	local j = makac.fs.path("/a"):join("b", "c.txt")
	api.eq(tostring(j), "/a/b/c.txt", "path:join method")
end)

api.t("pathdir", "dir_handle_operations", function()
	local d = api.dir("pd")
	local dir = makac.fs.open_dir(d)
	api.eq(dir:exists("nope"), false, "exists false before touch")
	dir:touch("newfile")
	api.eq(dir:exists("newfile"), true, "touch creates, exists true")
	dir:make_path("a/b")
	api.eq(makac.fs.stat(d .. "/a/b").type, "dir", "make_path creates nested dirs")
	local sub = dir:open_dir("a")
	api.eq(tostring(sub:path()), d .. "/a", "open_dir on a subdir; path() correct")
	api.eq(tostring(sub:parent():path()), d, "parent() climbs")
end)

api.t("pathdir", "dir_list_and_walk", function()
	local d = api.dir("pd-walk")
	makac.fs.mkdir_p(d .. "/sub")
	makac.fs.write_file(d .. "/f.txt", "x")
	makac.fs.write_file(d .. "/sub/g.txt", "y")
	local dir = makac.fs.open_dir(d)
	-- NOTE probed: Dir:list entries carry 'name' but is_dir is NIL
	-- (inconsistent with fs.listdir's {name,is_dir} — findings.md)
	local names = {}
	for _, e in ipairs(dir:list()) do names[#names + 1] = e.name end
	table.sort(names)
	api.eq(table.concat(names, ","), "f.txt,sub", "list yields entry names")
	-- walk: iterator over everything below (probed: returns a function)
	local seen, count = {}, 0
	for entry in dir:walk() do
		count = count + 1
		seen[tostring(entry)] = true
	end
	api.truthy(count >= 3, "walk sees dir contents recursively")
	api.truthy(seen[d .. "/f.txt"] or seen["f.txt"], "walk covers the file (abs or rel form)")
end)

api.t("pathdir", "dir_remove_is_recursive", function()
	local d = api.dir("pd-rm")
	local dir = makac.fs.open_dir(d)
	dir:make_path("deep/nest")
	dir:touch("deep/nest/f")
	dir:remove("deep")
	api.eq(makac.fs.stat(d .. "/deep"), nil, "recursive remove")
end)

api.t("pathdir", "open_dir_requires_a_directory", function()
	local d = api.dir("pd-err")
	makac.fs.write_file(d .. "/f", "x")
	api.raises(function() makac.fs.open_dir(d .. "/f") end, nil, "file is not a dir")
	api.raises(function() makac.fs.open_dir(d .. "/ghost") end, nil, "missing dir raises")
end)

api.t("pathdir", "cwd_dir_handle", function()
	local dir = makac.fs.cwd()
	api.eq(makac.fs.stat(tostring(dir:path())).type, "dir", "cwd() is a valid Dir")
end)
