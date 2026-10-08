-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- cases/qmp.lua — the QMP client (makac.qmp_open) driven through the CLI
-- against the scripted python fake server (servers/fake_qmp.py, vendored
-- verbatim from makac/qmp_test/). Wire behaviors pinned: greeting +
-- qmp_capabilities handshake in qmp_open, send batches in order with error
-- replies as DATA, the event buffer discipline (send clears once, poll
-- drains, events() reads without consuming, consume drops), deadlines on
-- unresponsive commands, lifecycle. Contracts: design/qmp.md.
--
-- Gated on python3 (auto-detect; the flake's 'testing' shell provides it).

local h = require("harness")

h.suite("qmp")

local SCRIPT = SCRIPT_DIR .. "/servers/fake_qmp.py"

local function have(bin)
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local st = makac.fs.stat(dir .. "/" .. bin)
		if st and (st.type == "file" or st.type == "link") then return true end
	end
	return false
end

--- Start the fake QMP server (unix socket + tcp); returns
--- { sock=..., host=..., port=..., pid=... } and a cleanup fn.
local function start_fake_qmp(ctx)
	local sock = ctx.path("qmp.sock")
	local port
	for p = 14555, 14590 do
		if makac.exec({ "nc", "-z", "127.0.0.1", tostring(p) }).code ~= 0 then port = p break end
	end
	assert(port, "no free TCP port for fake QMP")
	local outf, errf = ctx.path("qmp.out"), ctx.path("qmp.err")
	local proc = makac.spawn({ "python3", SCRIPT, sock, "127.0.0.1", tostring(port) },
		{ stdout = outf, stderr = errf })
	local ready = false
	for _ = 1, 100 do
		local out = makac.fs.read_file(outf)
		if out and out:find("READY", 1, true) then ready = true break end
		makac.time.sleep(50 * makac.time.ns_per_ms)
	end
	if not ready then
		error("fake QMP never ready: " .. (makac.fs.read_file(errf) or "<no stderr>"))
	end
	return { sock = sock, host = "127.0.0.1", port = port },
		function() pcall(makac.exec, { "kill", tostring(proc.pid) }) end
end

--- Run a qmp workflow body (formatted with sock/port), asserting success.
--- Returns the run result; caller asserts on stdout lines.
local function qwf(ctx, srv, body)
	ctx.write("w.lua", (body):format(srv.sock, srv.port))
	return ctx.run({ "run", "w.lua" }, { timeout_s = 60 })
end

h.case("qmp", "connect_handshake_lifecycle", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q) -- greeting + qmp_capabilities in open
print("opened: " .. tostring(type(q)))
q:close()
q:close() -- idempotent
local okrun = pcall(function() return q:send({ { execute = "query-block" } }) end)
print("use-after-close raises: " .. tostring(not okrun))
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "opened: userdata", "client object returned")
		h.contains(r.stdout, "use-after-close raises: true", "methods raise on a closed client")
		-- connect to a nonexistent socket raises promptly (no hang)
		local r2 = qwf(ctx, srv, [[
local ok, err = pcall(makac.qmp_open, %q .. ".nonexistent")
print("bad-sock raises: " .. tostring(not ok))
]])
		h.eq(r2.code, 0, "run exit: " .. r2.stderr)
		h.contains(r2.stdout, "bad-sock raises: true", "missing socket raises")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "send_reply_shapes_and_order", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q)
-- batch of two: results come back same length, same order
local res = q:send({ { execute = "query-block" }, { execute = "query-status" } })
print("count: " .. #res)
print("first.device:  " .. res[1]["return"][1].device)
print("second.status: " .. res[2]["return"].status)
print("second.bool:   " .. tostring(res[2]["return"].running) .. " (" .. type(res[2]["return"].running) .. ")")
-- QMP error replies are DATA, not raises
local res2 = q:send({ { execute = "bad-cmd" } })
print("err.class: " .. res2[1].error.class)
print("err.desc contains cmd: " .. tostring(res2[1].error.desc:find("bad-cmd", 1, true) ~= nil))
q:close()
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "count: 2", "one result per command")
		h.contains(r.stdout, "first.device:  drive0", "first reply (array payload, plain tables)")
		h.contains(r.stdout, "second.status: running", "second reply in position")
		h.contains(r.stdout, "second.bool:   true (boolean)", 'json "true" decodes to a Lua boolean')
		h.contains(r.stdout, "err.class: CommandNotFound", "QMP error as data")
		h.contains(r.stdout, "err.desc contains cmd: true", "error desc decoded")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "event_buffer_discipline", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q)
-- query-status pushes TWO events before its return; they stay buffered
-- after the send returns (the call cleared stale events at its START)
q:send({ { execute = "query-status" } })
local evs = q:events()
print("buffered: " .. #evs)
print("e1: " .. evs[1].name)
print("e1 has ts: " .. tostring(evs[1].timestamp ~= nil))
print("e2: " .. evs[2].name)
-- events() does NOT consume: reading again yields the same count
print("still buffered: " .. #q:events())
-- consume drops the oldest
q:consume(1)
print("after consume: " .. q:events()[1].name)
-- over-reading / over-consuming raise
local okE = pcall(function() return q:events(5) end)
local okC = pcall(function() q:consume(5) end)
print("over-read raises: " .. tostring(not okE) .. " over-consume raises: " .. tostring(not okC))
q:close()
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "buffered: 2", "events of the call buffered after send returns")
		h.contains(r.stdout, "e1: RTC_CHANGE", "event name decoded")
		h.contains(r.stdout, "e1 has ts: true", "timestamp carried through")
		h.contains(r.stdout, "e2: SPICE_INITIALIZED", "second event in order")
		h.contains(r.stdout, "still buffered: 2", "events() does not consume")
		h.contains(r.stdout, "after consume: SPICE_INITIALIZED", "consume dropped the oldest")
		h.contains(r.stdout, "over-read raises: true over-consume raises: true", "bounds raise")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "poll_and_send_clears_stale_events", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q)
-- emit-event: one async RESET then the return; buffered by the send
q:send({ { execute = "emit-event" } })
print("buffered after emit: " .. #q:events())
-- a new send clears stale events once at start; query-block fires none,
-- so the buffer is empty after it returns
q:send({ { execute = "query-block" } })
print("buffered after next send: " .. #q:events())
-- poll drains: fresh events arrive...
q:send({ { execute = "emit-event" } })
q:consume(1)
local arrived = q:poll({ timeout_s = 1 })
print("poll on idle: " .. tostring(arrived) .. " (timeout is benign, non-error)")
q:close()
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "buffered after emit: 1", "event buffered during send")
		h.contains(r.stdout, "buffered after next send: 0", "send clears stale events at start")
		h.contains(r.stdout, "poll on idle: false", "idle poll returns false, not an error")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "unresponsive_command_raises_on_deadline", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q)
local t0 = makac.time.now()
local okr = pcall(q.send, q, { { execute = "hang" } }, { timeout_s = 1 })
local elapsed = (makac.time.now() - t0) / makac.time.ns_per_s
print("hang raises: " .. tostring(not okr))
print("bounded: " .. tostring(elapsed < 5))
print("elapsed_s: " .. math.floor(elapsed * 10) / 10)
-- the client survives the timeout but the connection state is suspect;
-- close() must still work
q:close()
print("closed after timeout")
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "hang raises: true", "unresponsive command raises")
		h.contains(r.stdout, "bounded: true", "deadline honored (no indefinite block)")
		h.contains(r.stdout, "closed after timeout", "lifecycle survives the timeout")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "json_numbers_decode_integers", function(ctx)
	-- design/qmp.md: 'JSON numbers decode with integers staying integers'.
	-- REFERENCE DIVERGES (floats; findings.md) — quarantined via MAKAC_BB_SKIP
	-- when run against Odin; the Zig port must pass it unquarantined.
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		local r = qwf(ctx, srv, [[
local q = makac.qmp_open(%q)
q:send({ { execute = "query-status" } })
local ev = q:events()[1]
print("event data offset type: " .. tostring(math.type(ev.data.offset)))
print("event ts seconds type:  " .. tostring(math.type(ev.timestamp.seconds)))
q:close()
]])
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "event data offset type: integer", "integer in event data")
		h.contains(r.stdout, "event ts seconds type:  integer", "integer in timestamp")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)

h.case("qmp", "tcp_transport", function(ctx)
	if not have("python3") then print("# skip: python3 unavailable") return end
	local srv, cleanup = start_fake_qmp(ctx)
	local ok, err = pcall(function()
		ctx.write("w2.lua", ([[
local q = makac.qmp_open({ tcp = "127.0.0.1:%d" })
local res = q:send({ { execute = "query-block" } })
print("tcp device: " .. res[1]["return"][1].device)
q:close()
]]):format(srv.port))
		local r = ctx.run({ "run", "w2.lua" }, { timeout_s = 60 })
		h.eq(r.code, 0, "run exit: " .. r.stderr)
		h.contains(r.stdout, "tcp device: drive0", "same client over a TCP endpoint")
	end)
	cleanup()
	if not ok then error(err, 0) end
end)
