-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/download.lua — makac.download + the fetchurl fetcher over a loopback
-- HTTP server (python3 http.server serving per-case fixture files). Hermetic:
-- loopback only. Covers URL-keyed caching, checksum verification (match,
-- mismatch, corrupt-entry refetch), HTTP errors, tar + custom unpackers,
-- and the fetchurl key-purity contract (unpacker must NOT affect the key).
-- Contracts: site/src/lua-api/makac-api.md (Downloads), reference/fetchers.md
-- (fetchurl), downloader/downloader.odin docstring.
--
-- Gated on python3 (auto-detect; the flake's 'testing' shell provides it).

local h = require("harness")

h.suite("download")

local function have(bin)
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local st = makac.fs.stat(dir .. "/" .. bin)
		if st and (st.type == "file" or st.type == "link") then return true end
	end
	return false
end

--- Spawn `python3 -m http.server` serving <tmp>/www; returns
--- { base="http://127.0.0.1:P", port=..., gets=fn } and a cleanup fn.
--- gets(path) counts request-log lines for that path (proves cache hits).
local function start_http(ctx)
	ctx.mkdir_p("www")
	local port
	for p = 18801, 18860 do
		if makac.exec({ "nc", "-z", "127.0.0.1", tostring(p) }).code ~= 0 then port = p break end
	end
	assert(port, "no free TCP port for http.server")
	local outf, errf = ctx.path("http.out"), ctx.path("http.err")
	local proc = makac.spawn({ "python3", "-m", "http.server", tostring(port),
		"--directory", ctx.path("www") }, { stdout = outf, stderr = errf })
	local base = ("http://127.0.0.1:%d"):format(port)
	local ready = false
	for _ = 1, 100 do
		if makac.exec({ "curl", "-sf", base .. "/" }).code == 0 then ready = true break end
		makac.time.sleep(50 * makac.time.ns_per_ms)
	end
	if not ready then error("http.server never ready: " .. (makac.fs.read_file(errf) or "")) end
	local function gets(path)
		local log = makac.fs.read_file(errf) or ""
		local _, n = log:gsub("GET " .. path:gsub("%W", "%%%0"), "")
		return n
	end
	return { base = base, port = port, gets = gets },
		function() pcall(makac.exec, { "kill", tostring(proc.pid) }) end
end

local function project(ctx)
	h.eq(ctx.run({ "init", ctx.path("proj") }).code, 0, "init")
	return ctx.path("proj")
end

--- Write a payload file into www/ with given content; returns url + sha.
local function serve_file(ctx, srv, name, content)
	makac.fs.write_file(ctx.path("www/" .. name), content)
	return srv.base .. "/" .. name, makac.sha256(content)
end

-- --- makac.download -------------------------------------------------------------

h.case("download", "download_caches_by_url_and_serves_hits", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, _ = serve_file(ctx, srv, "payload.txt", "PAYLOAD-v1\n")
		ctx.write("proj/w.lua", ([[
local p1 = makac.download(%q)
print("content: " .. makac.fs.read_file(tostring(p1)):gsub("%%s+$", ""))
local p2 = makac.download(%q)
print("same path on hit: " .. tostring(p1 == p2))
print("under cache dir: " .. tostring(tostring(p1):find("/.makac/cache/", 1, true) ~= nil))
]]):format(url, url))
		local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "content: PAYLOAD-v1", "downloaded content")
		h.contains(r.stdout, "same path on hit: true", "second download served from cache")
		h.contains(r.stdout, "under cache dir: true", "default cache is <data_dir>/cache")
		-- the cache file is named sha256(url)
		local entries = makac.fs.listdir(proj .. "/.makac/cache")
		h.eq(#entries, 1, "one cache entry")
		h.eq(entries[1].name, makac.sha256(url), "cache entry named sha256(url)")
		h.eq(srv.gets("/payload.txt"), 1, "exactly ONE HTTP GET for two downloads")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "checksum_verified_mismatch_raises", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, sha = serve_file(ctx, srv, "c.txt", "CHECK-ME")
		local wrongsha = makac.sha256("not-the-content")
		ctx.write("proj/w.lua", ([[
local p = makac.download(%q, %q)
print("verified: " .. makac.fs.read_file(tostring(p)))
local okm, errm = pcall(makac.download, %q .. "?v=2", %q)
print("mismatch raises: " .. tostring(not okm))
print("mentions checksum: " .. tostring(not okm and tostring(errm):find("checksum") ~= nil))
]]):format(url, sha, url, wrongsha))
		local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "verified: CHECK-ME", "matching sha256 passes")
		h.contains(r.stdout, "mismatch raises: true", "checksum mismatch is an error")
		h.contains(r.stdout, "mentions checksum: true", "error says checksum")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "corrupt_cache_entry_dropped_and_refetched", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, sha = serve_file(ctx, srv, "r.txt", "REFETCH-ME")
		ctx.write("proj/w.lua", ([[
local p = makac.download(%q, %q)
print("first: " .. makac.fs.read_file(tostring(p)))
]]):format(url, sha))
		h.eq(ctx.run({ "run", "w.lua" }, { chdir = proj }).code, 0, "first download")
		h.eq(srv.gets("/r.txt"), 1, "one GET")
		-- corrupt the cache entry out from under it
		local cached = proj .. "/.makac/cache/" .. makac.sha256(url)
		makac.fs.write_file(cached, "CORRUPTED")
		ctx.write("proj/w2.lua", ([[
local p = makac.download(%q, %q)
print("second: " .. makac.fs.read_file(tostring(p)))
]]):format(url, sha))
		local r2 = ctx.run({ "run", "w2.lua" }, { chdir = proj })
		h.eq(r2.code, 0, "run exit: " .. r2.stderr)
		h.contains(r2.stdout, "second: REFETCH-ME", "corrupt entry re-verified, dropped, refetched")
		h.eq(srv.gets("/r.txt"), 2, "refetch hit the server once more")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "http_error_and_unreachable_raise", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		ctx.write("proj/w.lua", ([[
local ok404 = pcall(makac.download, %q .. "/no-such-file")
print("404 raises: " .. tostring(not ok404))
local okdead, errdead = pcall(makac.download, "http://127.0.0.1:1/never")
print("dead raises: " .. tostring(not okdead))
]]):format(srv.base))
		local r = ctx.run({ "run", "w.lua" }, { chdir = proj, timeout_s = 60 })
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "404 raises: true", "HTTP error status raises")
		h.contains(r.stdout, "dead raises: true", "connection failure raises")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

-- --- fetchurl -------------------------------------------------------------------

--- Build a tarball in www/ with the package at the tar ROOT; return url, sha.
local function serve_tar(ctx, srv, name, files)
	ctx.mkdir_p("tarroot")
	for rel, body in pairs(files) do
		local full = "tarroot/" .. rel
		makac.fs.mkdir_p((ctx.path(full):gsub("/[^/]*$", "")))
		makac.fs.write_file(ctx.path(full), body)
	end
	h.eq(makac.exec({ "tar", "-cf", ctx.path("www/" .. name), "-C", ctx.path("tarroot"), "." }).code, 0, "tar")
	local content = assert(makac.fs.read_file(ctx.path("www/" .. name)))
	return srv.base .. "/" .. name, makac.fs.sha256(ctx.path("www/" .. name))
end

h.case("download", "fetchurl_tar_cycle_and_cache_reuse", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, sha = serve_tar(ctx, srv, "pkg.tar", {
			["makac_package.lua"] = [[
return { actions = { hi = function() return { out = { v = "tar-pkg" } } end } }
]],
			["lib/extra.lua"] = [[return { MARK = "lib-in-tar" }]],
		})
		local project_lua = ([[
return {
  inputs = { t = { fetcher = "fetchurl", with = { url = %q, sha256 = %q, unpacker = "tar" } } },
  packages = { tp = "t" },
}
]]):format(url, sha)
		makac.fs.write_file(proj .. "/makac_project.lua", project_lua)
		local f = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f.code, 0, "fetch exit: " .. f.stderr)
		h.contains(f.stdout, "fetching t via fetchurl", "fetch report")
		local entries = makac.fs.listdir(proj .. "/.makac/packages")
		h.eq(#entries, 1, "one stored package")
		h.matches(entries[1].name, "^fetchurl%-%x+$", "fetchurl key shape")
		-- tar extracted AT the key dir's root (makac_package.lua must be there)
		ctx.write("proj/w.lua", [[
local r = step { uses = "tp:hi", with = {} }
print("action: " .. r.out.v)
print("lib: " .. require("pkgs/tp/extra").MARK)
]])
		local r = ctx.run({ "run", "w.lua" }, { chdir = proj })
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "action: tar-pkg", "unpacked package loads and runs")
		h.contains(r.stdout, "lib: lib-in-tar", "lib require-able")
		h.eq(srv.gets("/pkg.tar"), 1, "one GET")
		-- re-fetch: download cache serves the same URL again (no new GET)
		local f2 = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f2.code, 0, "re-fetch exit: " .. f2.stderr)
		h.eq(srv.gets("/pkg.tar"), 1, "re-fetch served from the download cache")
		h.eq(#makac.fs.listdir(proj .. "/.makac/packages"), 1, "still one stored package")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "fetchurl_custom_unpacker_function", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, sha = serve_tar(ctx, srv, "c.tar", {
			["makac_package.lua"] = [[return { actions = {} }]],
			["marker.txt"] = "inside-tar",
		})
		makac.fs.write_file(proj .. "/makac_project.lua", ([[
return {
  inputs = {
    c = { fetcher = "fetchurl",
          with = { url = %q, sha256 = %q,
                   unpacker = function(args, dst)
                     -- contract: args.archive is the downloaded file, dst the dest
                     local content = makac.fs.read_file(args.archive)
                     assert(content ~= nil)
                     local r = makac.exec({ "tar", "-xf", args.archive, "-C", dst })
                     assert(r.code == 0, r.stderr)
                     -- prove the custom unpacker ran by moving the marker
                     local m = makac.fs.read_file(dst .. "/marker.txt")
                     makac.fs.write_file(dst .. "/unpacked-by-fn.txt", m)
                   end } },
  },
  packages = { c = "c" },
}
]]):format(url, sha))
		local f = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f.code, 0, "fetch exit: " .. f.stderr)
		local key = makac.fs.listdir(proj .. "/.makac/packages")[1].name
		h.eq(makac.fs.read_file(proj .. "/.makac/packages/" .. key .. "/unpacked-by-fn.txt"),
			"inside-tar", "custom unpacker received {archive} and dst")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "fetchurl_key_excludes_unpacker", function(ctx)
	-- docs (reference/fetchers.md): fields that cannot change the result
	-- must NOT participate in the key — same url+sha256, different unpacker,
	-- same key. Probed on the reference: identical keys, download served from
	-- cache (one GET), unpacker still runs per input.
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, sha = serve_tar(ctx, srv, "k.tar", {
			["makac_package.lua"] = [[return { actions = {} }]],
		})
		makac.fs.write_file(proj .. "/makac_project.lua", ([[
return {
  inputs = {
    a = { fetcher = "fetchurl", with = { url = %q, sha256 = %q, unpacker = "tar" } },
    b = { fetcher = "fetchurl", with = { url = %q, sha256 = %q, unpacker = function(args, dst)
            local r = makac.exec({ "tar", "-xf", args.archive, "-C", dst })
            assert(r.code == 0, r.stderr)
          end } },
  },
  packages = { a = "a", b = "b" },
}
]]):format(url, sha, url, sha))
		local f = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f.code, 0, "fetch exit: " .. f.stderr)
		h.eq(#makac.fs.listdir(proj .. "/.makac/packages"), 1, "unpacker is not part of the key")
		h.eq(srv.gets("/k.tar"), 1, "download cache shared across the two inputs")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "fetchurl_checksum_mismatch_aborts_fetch", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		local url, _ = serve_tar(ctx, srv, "m.tar", {
			["makac_package.lua"] = [[return { actions = {} }]],
		})
		makac.fs.write_file(proj .. "/makac_project.lua", ([[
return {
  inputs = { m = { fetcher = "fetchurl", with = { url = %q, sha256 = %q, unpacker = "tar" } } },
  packages = { m = "m" },
}
]]):format(url, makac.sha256("wrong")))
		local f = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f.code, 1, "checksum mismatch aborts the fetch run")
		h.contains(f.stderr, "checksum", "mismatch named in the error")
		h.contains(f.stderr, "'m'", "names the input")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("download", "fetchurl_field_validation", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_http(ctx)
	local ok, err = pcall(function()
		local proj = project(ctx)
		-- missing sha256
		makac.fs.write_file(proj .. "/makac_project.lua", ([[
return {
  inputs = { x = { fetcher = "fetchurl", with = { url = %q, unpacker = "tar" } } },
  packages = { x = "x" },
}
]]):format(srv.base .. "/anything"))
		local f = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f.code, 1, "missing sha256 fails")
		h.contains(f.stderr, "sha256", "names the missing field")
		-- missing unpacker
		local _url, sha = serve_file(ctx, srv, "f.bin", "x")
		makac.fs.write_file(proj .. "/makac_project.lua", ([[
return {
  inputs = { x = { fetcher = "fetchurl", with = { url = %q, sha256 = %q } } },
  packages = { x = "x" },
}
]]):format(srv.base .. "/f.bin", sha))
		local f2 = ctx.run({ "fetch" }, { chdir = proj })
		h.eq(f2.code, 1, "missing unpacker fails")
		h.contains(f2.stderr, "unpacker", "names the missing field")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)
