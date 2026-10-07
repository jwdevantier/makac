-- cases/primitives.lua — the host-provided makac.* primitives, one exercised
-- case each, through the CLI. These are the functions the Zig port must
-- provide to the embedded Lua VM; the DSL on top of them is prelude.lua
-- (verbatim) and covered by the other suites.
-- Contracts: site/src/lua-api/makac-api.md.

local h = require("harness")

h.suite("primitives")

local function workflow(ctx, body)
	ctx.write("w.lua", body)
	return ctx.run({ "run", "w.lua" })
end

h.case("primitives", "exec_captures_and_nonzero_is_data", function(ctx)
	local r = workflow(ctx, [[
local res = makac.exec({ "sh", "-c", "printf o; printf e >&2; exit 5" })
print("code:   " .. res.code)
print("stdout: " .. res.stdout)
print("stderr: " .. res.stderr)
print("timed_out: " .. tostring(res.timed_out))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "code:   5", "non-zero exit is data, not a raise")
	h.contains(r.stdout, "stdout: o", "stdout captured")
	h.contains(r.stdout, "stderr: e", "stderr captured")
	h.contains(r.stdout, "timed_out: false", "timed_out field present")
end)

h.case("primitives", "exec_env_merges_and_spawn_failure_raises", function(ctx)
	local r = workflow(ctx, [[
local res = makac.exec({ "printenv", "BB_PRIM" }, { env = { BB_PRIM = "merged" } })
print("env: " .. res.stdout)
local ok, err = pcall(makac.exec, { "no-such-program-bb" })
print("raised: " .. tostring(ok == false and err ~= nil))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "env: merged", "env option merged on top of process env")
	h.contains(r.stdout, "raised: true", "spawn failure raises (not data)")
end)

h.case("primitives", "fs_roundtrip_and_errors_as_data", function(ctx)
	local r = workflow(ctx, ([[
local d = %q
makac.fs.mkdir_p(d .. "/a/b")
makac.fs.write_file(d .. "/a/b/f.txt", "payload")
print("read: " .. makac.fs.read_file(d .. "/a/b/f.txt"))
local missing, merr = makac.fs.read_file(d .. "/nope")
print("missing: " .. tostring(missing == nil) .. " " .. tostring(type(merr) == "string"))
local st = makac.fs.stat(d .. "/a/b")
print("stat: " .. tostring(st.type) .. " absent:" .. tostring(makac.fs.stat(d .. "/nope") == nil))
local entries = makac.fs.listdir(d .. "/a")
print("listdir: " .. entries[1].name .. ":" .. tostring(entries[1].is_dir))
]]):format(ctx.tmp))
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "read: payload", "write_file/read_file roundtrip")
	h.contains(r.stdout, "missing: true true", "unreadable file returns (nil, err), no raise")
	h.contains(r.stdout, "stat: dir absent:true", "stat type + nil for missing")
	h.contains(r.stdout, "listdir: b:true", "listdir entries have name and is_dir")
end)

h.case("primitives", "fs_write_file_atomic_and_symlink", function(ctx)
	local r = workflow(ctx, ([[
local d = %q
makac.fs.write_file(d .. "/a.txt", "v1", { atomic = true })
makac.fs.write_file(d .. "/a.txt", "v2", { atomic = true })
print("atomic: " .. makac.fs.read_file(d .. "/a.txt"))
makac.fs.symlink(d .. "/a.txt", d .. "/l")
makac.fs.symlink(d .. "/a.txt", d .. "/l") -- replace, not error
print("link: " .. tostring(makac.fs.stat(d .. "/l").type))
print("sha256: " .. makac.fs.sha256(d .. "/a.txt"))
]]):format(ctx.tmp))
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "atomic: v2", "atomic write replaces content")
	h.contains(r.stdout, "link: link", "symlink created and replaced (lstat type)")
	-- sha256("v2") is a fixed vector:
	h.contains(r.stdout, "sha256: fb04dcb6970e4c3d1873de51fd5a50d7bb46b3383113602665c350ec40b5f990", "streamed file sha256")
end)

h.case("primitives", "path_values_and_dir_handles", function(ctx)
	local r = workflow(ctx, ([[
-- NOTE: path values are NOT strings; dirname()/basename() return strings? No:
-- methods return path values where a path results — tostring() to compare.
local p = makac.fs.path_join(%q, "x", "y.txt")
print("join:   " .. tostring(p))
print("base:   " .. p:basename())
print("dir:    " .. tostring(p:dirname()):sub(-8))
local dir = makac.fs.open_dir(%q)
print("cwd is Dir: " .. tostring(type(dir) == "userdata" or type(dir) == "table"))
print("sep: " .. makac.fs.sep)
print("null: " .. tostring(makac.fs.null_file()))
]]):format(ctx.tmp, ctx.tmp))
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "base:   y.txt", "basename on path value")
	h.contains(r.stdout, "sep: /", "platform separator")
	h.contains(r.stdout, "null: /dev/null", "null device path")
end)

h.case("primitives", "json_roundtrip", function(ctx)
	local r = workflow(ctx, [[
local t = { name = "bb", n = 42, list = { 1, 2, 3 }, nested = { flag = true } }
local s = makac.json.dumps(t)
local back = makac.json.loads(s)
print("name:   " .. back.name)
print("n:      " .. back.n)
print("list:   " .. #back.list .. "/" .. back.list[2])
print("nested: " .. tostring(back.nested.flag))
local ok = pcall(makac.json.loads, "{ invalid json")
print("bad json raises: " .. tostring(ok == false))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "name:   bb", "string survives")
	h.contains(r.stdout, "n:      42", "number survives")
	h.contains(r.stdout, "list:   3/2", "array survives")
	h.contains(r.stdout, "nested: true", "nested bool survives")
	h.contains(r.stdout, "bad json raises: true", "parse failure raises")
end)

h.case("primitives", "sha256_and_random_hex", function(ctx)
	local r = workflow(ctx, [[
-- known vectors
print("empty: " .. makac.sha256(""))
print("abc:   " .. makac.sha256("abc"))
local a, b = makac.random_hex(8), makac.random_hex(8)
print("rand ok: " .. tostring(#a == 8 and a:match("^[0-9a-f]+$") ~= nil and a ~= b))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "empty: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty vector")
	h.contains(r.stdout, "abc:   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc vector")
	h.contains(r.stdout, "rand ok: true", "random_hex: length, charset, uniqueness")
end)

h.case("primitives", "time_now_sleep_constants", function(ctx)
	local r = workflow(ctx, [[
local t0 = makac.time.now()
makac.time.sleep(10 * makac.time.ns_per_ms)
local t1 = makac.time.now()
print("monotonic: " .. tostring(t1 > t0))
print("slept enough: " .. tostring(t1 - t0 >= 10 * makac.time.ns_per_ms))
print("const: " .. makac.time.ns_per_us .. "," .. makac.time.ns_per_ms .. "," .. makac.time.ns_per_s)
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "monotonic: true", "now() advances")
	h.contains(r.stdout, "slept enough: true", "sleep() lasts at least as long")
	h.contains(r.stdout, "const: 1000,1000000,1000000000", "ns constants")
end)

h.case("primitives", "env_version_and_makac_path", function(ctx)
	local r = workflow(ctx, [[
local all = makac.env.all()
print("has PATH: " .. tostring(type(all.PATH) == "string"))
local maj, min = makac.env.version()
print("version ints: " .. tostring(type(maj) == "number" and type(min) == "number"))
print("version: " .. maj .. "." .. min)
local p = tostring(makac.env.makac_path()) -- returns a path value
print("makac_path abs: " .. tostring(p:sub(1, 1) == "/" and makac.fs.stat(p) ~= nil))
]])
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "has PATH: true", "env.all exposes the environment")
	h.contains(r.stdout, "version ints: true", "version returns two integers")
	-- the suite's binary under test is makac; env.makac_path points at IT
	h.contains(r.stdout, "makac_path abs: true", "running binary path is absolute and exists")
end)

h.case("primitives", "spawn_proc_status_and_pid_alive", function(ctx)
	local r = workflow(ctx, ([[
local d = %q
local proc = makac.spawn({ "sh", "-c", "sleep 0.3; printf done > " .. %q },
	{ stdout = %q, stderr = %q })
print("pid is number: " .. tostring(type(proc.pid) == "number"))
print("alive while running: " .. tostring(makac.pid_alive(proc.pid)))
local st = proc:status()
print("status running/table: " .. tostring(st == "running" or type(st) == "table"))
-- wait for exit
while proc:status() == "running" do makac.time.sleep(50 * makac.time.ns_per_ms) end
print("final code: " .. proc:status().code)
print("file: " .. makac.fs.read_file(d .. "/out.txt"))
print("alive after exit: " .. tostring(makac.pid_alive(proc.pid)))
]]):format(ctx.tmp, ctx.path("out.txt"), ctx.path("spawn.out"), ctx.path("spawn.err")))
	h.eq(r.code, 0, "exit code: " .. r.stderr)
	h.contains(r.stdout, "pid is number: true", "proc.pid is an integer")
	h.contains(r.stdout, "alive while running: true", "pid_alive during run")
	h.contains(r.stdout, "status running/table: true", "status shape")
	h.contains(r.stdout, "final code: 0", "reaped exit code")
	h.contains(r.stdout, "file: done", "spawned child ran to completion")
	h.contains(r.stdout, "alive after exit: false", "pid released after reap")
end)
