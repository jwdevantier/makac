-- cases/ssh.lua — SSH targets, three tiers:
--
--   * 'ssh' suite (always-on, hermetic): PATH-injected FAKE ssh/scp binaries
--     that log their argv and EXECUTE the assembled remote command locally.
--     This pins the whole mechanism layer without a daemon: config generation
--     (.makac/targets/<name>/), the -F invocation shape, remote env/shell
--     wrapping, cd && , 2>&1 join, put/get directionality.
--   * 'unreachable_host' (always-on): real ssh against a closed port; the
--     failure must be an error, cleanly, fast — not a hang, not data.
--   * 'ssh_real' suite (auto-detect sshd+ssh-keygen, opt-out MAKAC_TEST_SSH=0):
--     a self-contained localhost sshd; real run/put/get, multiplexing, close.
--
-- Contracts: site/src/concepts/targets.md, reference/target.md,
-- design/target.md. Mechanism in vm/ssh_target.odin + ssh/*.odin, policy
-- (assembly) in prelude.lua.

local h = require("harness")

-- --- fixture helpers ----------------------------------------------------------

local function have(bin)
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = dir .. "/" .. bin
		local st = makac.fs.stat(p)
		if st and (st.type == "file" or st.type == "link") then return p end
	end
	return nil
end

local function ssh_cases_enabled()
	local v = (os.getenv("MAKAC_TEST_SSH") or ""):lower()
	return not (v == "0" or v == "false" or v == "no" or v == "off")
end

--- Project dir with a makac data dir (targets keep state in it).
local function ssh_project(ctx)
	h.eq(ctx.run({ "init", ctx.path("proj") }).code, 0, "init")
	return ctx.path("proj")
end

--- Write fake ssh/scp into <tmp>/fakebin; both log to <tmp>/invocations.log
--- and then act locally: fake ssh executes the assembled remote command under
--  /bin/sh (functional test of the assembly); fake scp cp -r's, direction
--  inferred from which argument gained the '<host>:' prefix.
local function install_fake_ssh(ctx)
	ctx.mkdir_p("fakebin")
	local log = ctx.path("invocations.log")
	local ssh = (ctx.path("fakebin/ssh"))
	makac.fs.write_file(ssh, ([[
#!/bin/sh
printf 'SSH' >> %q
for a in "$@"; do printf ' [%%s]' "$a" >> %q; done
printf '\n' >> %q
for last do :; done   # remote command is the last word
exec /bin/sh -c "$last"
]]):format(log, log, log))
	local scp = (ctx.path("fakebin/scp"))
	-- plain rewrite: log argv; take the last two non-option words as src/dst
	-- (options that consume the following word are skipped); strip the
	-- '<host>:' prefix from whichever side carries it; copy locally.
	makac.fs.write_file(scp, ([[
#!/bin/sh
{
  printf 'SCP'
  for a in "$@"; do printf ' [%%s]' "$a"; done
  printf '\n'
} >> %q
skip=0
last1=""
last2=""
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -F|-P|-o|-i|-S) skip=1 ;;
    -*) ;;
    *) last2="$last1"; last1="$a" ;;
  esac
done
src="$last2"; dst="$last1"
# remote sides (host:path) are jailed under %q so the local copy mimics a
# remote filesystem; absolute stays-absolute relative lands in remote 'home'
jail() { case "$1" in /*) printf '%%s%%s' %q "$1" ;; *) printf '%%s/home/%%s' %q "$1" ;; esac; }
case "$src" in *:*) src="$(jail "${src#*:}")" ;; esac
case "$dst" in *:*) dst="$(jail "${dst#*:}")"; mkdir -p "$(dirname "$dst")" ;; esac
exec cp -R "$src" "$dst"
]]):format(log, ctx.path("remote"), ctx.path("remote"), ctx.path("remote")))
	for _, p in ipairs({ ssh, scp }) do
		h.eq(makac.exec({ "chmod", "+x", p }).code, 0, "chmod fake")
	end
	return { PATH = ctx.path("fakebin") .. ":" .. (os.getenv("PATH") or "") }
end

-- Wait: makac invokes ssh/scp via PATH resolution in the BINARY-UNDER-TEST's
-- environment; ctx.run opts.env merges PATH on top. Good.

--- Run one workflow (body) inside the ssh project, with the fakes on PATH.
local function wf(ctx, proj, extra_env, body)
	ctx.write("proj/w.lua", body)
	local env = {}
	for k, v in pairs(extra_env or {}) do env[k] = v end
	return ctx.run({ "run", "w.lua" }, { chdir = proj, env = env, timeout_s = 30 })
end

local function invocation_log(ctx)
	return makac.fs.read_file(ctx.path("invocations.log")) or ""
end

-- --- suite: ssh (fake binaries, always-on) -------------------------------------

h.suite("ssh")

h.case("ssh", "functional_assembly_env_chdir_join", function(ctx)
	local fakeenv = install_fake_ssh(ctx)
	local proj = ssh_project(ctx)
	local r = wf(ctx, proj, fakeenv, [[
local t = makac.new_ssh_target("vm1", {
  host = "example.internal", user = "bbuser", port = 2222,
  options = { IdentityFile = "/id/testkey", StrictHostKeyChecking = "no" },
})
-- env: prelude wraps as sh -c 'BB_VAR=... cmd' — fake ssh runs it locally
local r1 = t:run({ "printenv", "BB_VAR" }, { env = { BB_VAR = "x y z" } })
print("env: out=" .. r1.stdout)
-- chdir: becomes cd X && cmd
local r2 = t:run({ "pwd" }, { chdir = "/usr" })
print("chdir: out=" .. r2.stdout:gsub("%s+$", ""))
-- join: remote 2>&1 merges stderr into stdout
local r3 = t:run({ "sh", "-c", "printf o; printf e >&2" }, { join = true })
print("join: out=[" .. r3.stdout .. "] err=[" .. r3.stderr .. "]")
-- stdin is piped to the remote command
local r4 = t:run({ "cat" }, { stdin = "piped-over-ssh" })
print("stdin: out=" .. r4.stdout)
t:close()
]])
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "env: out=x y z", "remote env assignment worked (sorted, quoted)")
	h.contains(r.stdout, "chdir: out=/usr", "cd && applied")
	h.contains(r.stdout, "join: out=[oe] err=[]", "remote 2>&1 merged stderr into stdout")
	h.contains(r.stdout, "stdin: out=piped-over-ssh", "stdin reached the remote command")
	local log = invocation_log(ctx)
	h.contains(log, "-F", "ssh invoked with a config file (-F)")
	h.contains(log, "targets/vm1", "config lives under the target's state dir")
	-- env assignments appear BEFORE the command in the assembled cmdline
	local line = log:match("[^\n]*BB_VAR[^\n]*") or ""
	h.truthy(line:find("BB_VAR=", 1, true) < line:find("printenv", 1, true),
		"env assignment precedes the command")
	h.contains(line, "sh -c", "wrapped in the chosen shell")
end)

h.case("ssh", "generated_config_with_multiplexing", function(ctx)
	local fakeenv = install_fake_ssh(ctx)
	local proj = ssh_project(ctx)
	local r = wf(ctx, proj, fakeenv, [[
local t = makac.new_ssh_target("vm1", {
  host = "example.internal", user = "bbuser", port = 2222,
  options = { IdentityFile = "/id/testkey", StrictHostKeyChecking = "no" },
})
t:run({ "true" })
t:close()
]])
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	-- locate the generated config by content
	local dir = proj .. "/.makac/targets/vm1"
	local entries = makac.fs.listdir(dir)
	h.truthy(entries and #entries > 0, "target state dir populated")
	local cfg
	for _, e in ipairs(entries or {}) do
		local body = makac.fs.read_file(dir .. "/" .. e.name)
		if body and body:find("HostName", 1, true) then cfg = body end
	end
	h.truthy(cfg, "an OpenSSH config was generated")
	h.contains(cfg, "HostName example.internal", "host rendered")
	h.contains(cfg, "User bbuser", "user rendered")
	h.not_contains(cfg, "Port", "port is NOT in the config (travels as -p; probed)")
	h.contains(cfg, "IdentityFile /id/testkey", "options rendered")
	h.contains(cfg, "StrictHostKeyChecking no", "options rendered (2)")
	h.contains(cfg, "ControlMaster", "multiplexing: control master")
	h.contains(cfg, "ControlPath", "multiplexing: socket path")
	h.contains(cfg, "ControlPersist", "multiplexing: persist")
	-- probed: the PORT travels on the command line, not in the config
	local log = invocation_log(ctx)
	h.contains(log, "[-p] [2222]", "port passed as -p on the ssh command line")
	-- probed: close() kills the control master via ssh -O exit
	h.contains(log, "[-O] [exit]", "close tears down the multiplex master")
end)

h.case("ssh", "put_get_directionality_and_roundtrip", function(ctx)
	local fakeenv = install_fake_ssh(ctx)
	local proj = ssh_project(ctx)
	ctx.write("upload.txt", "payload-123")
	local r = wf(ctx, proj, fakeenv, ([[
local t = makac.new_ssh_target("vm1", { host = "x", user = "u" })
t:put(%q, "/remote/landing/uploaded.txt")
t:get("/remote/landing/uploaded.txt", %q)
t:close()
]]):format(ctx.path("upload.txt"), ctx.path("downloaded.txt")))
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.eq(makac.fs.read_file(ctx.path("downloaded.txt")), "payload-123", "put+get roundtrip")
	local log = invocation_log(ctx)
	local putline = log:match("SCP[^\n]*") or ""
	-- probed: the address argument is literally 'localhost:<path>' — the real
	-- host comes from the config's HostName; directionality: SRC then host:DST
	h.contains(putline, "localhost:", "put prefixes the TARGET side with <host>:")
	local pos_src = putline:find("upload.txt]", 1, true)
	local pos_dst = putline:find("localhost:", 1, true)
	h.truthy(pos_src and pos_dst and pos_src < pos_dst, "put order: scp SRC host:DST")
end)

h.case("ssh", "close_semantics_and_remote_option_rejections", function(ctx)
	local fakeenv = install_fake_ssh(ctx)
	local proj = ssh_project(ctx)
	local r = wf(ctx, proj, fakeenv, [[
local t = makac.new_ssh_target("vm1", { host = "x", user = "u" })
-- timeout_s / on_line are host-only for now: clear rejections
local ok1, e1 = pcall(t.run, t, { "true" }, { timeout_s = 1 })
print("timeout_s rejected: " .. tostring(not ok1 and tostring(e1):find("not supported") ~= nil))
local ok2, e2 = pcall(t.run, t, { "true" }, { on_line = function() end })
print("on_line rejected: " .. tostring(not ok2 and tostring(e2):find("not supported") ~= nil))
t:close()
t:close() -- idempotent
local ok3 = pcall(t.run, t, { "true" })
print("run after close fails: " .. tostring(not ok3))
print("done")
]])
	h.eq(r.code, 0, "run exit: " .. r.stderr)
	h.contains(r.stdout, "timeout_s rejected: true", "timeout_s unsupported remotely")
	h.contains(r.stdout, "on_line rejected: true", "on_line unsupported remotely")
	h.contains(r.stdout, "run after close fails: true", "closed target rejects ops")
end)

h.case("ssh", "unreachable_host_fails_the_step_cleanly", function(ctx)
	-- REAL ssh here (not the fake): closed port on localhost, short timeout.
	-- A connection failure must FAIL — as an error, quickly; never hang,
	-- never silently return data with code 0.
	local proj = ssh_project(ctx)
	local r = wf(ctx, proj, nil, [[
local t = makac.new_ssh_target("dead", {
  host = "127.0.0.1", user = "nobody", port = 1,
  options = {
    ConnectTimeout = "2", BatchMode = "yes",
    StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null",
  },
})
step { name = "touch the void", uses = "shell", target = t, with = { cmd = { "true" } } }
]])
	h.eq(r.code, 1, "connection failure fails the run")
	h.eq(r.timed_out, false, "did not hang (came back promptly)")
	h.matches(r.stderr, "failed: %[dead%]", "failed status against the target name")
end)

-- --- suite: ssh_real (auto-detected localhost sshd) ------------------------------

h.suite("ssh_real")

--- Start a self-contained sshd in the case's tmp dir; returns
--- new_ssh_target spec + a cleanup function. Caller wraps in pcall.
local function start_sshd(ctx)
	local sshd = assert(have("sshd"), "sshd not on PATH")
	local keygen = assert(have("ssh-keygen"), "ssh-keygen not on PATH")
	local d = ctx.tmp
	-- keys
	h.eq(makac.exec({ keygen, "-t", "ed25519", "-N", "", "-q", "-f", d .. "/id" }).code, 0, "client key")
	h.eq(makac.exec({ keygen, "-t", "ed25519", "-N", "", "-q", "-f", d .. "/hostkey" }).code, 0, "host key")
	local pub = assert(makac.fs.read_file(d .. "/id.pub"))
	makac.fs.write_file(d .. "/authorized_keys", pub)
	-- a free port: nc -z fails on closed ports; scan a small range
	local port
	for p = 22222, 22260 do
		if makac.exec({ "nc", "-z", "127.0.0.1", tostring(p) }).code ~= 0 then port = p break end
	end
	assert(port, "no free port in 22222..22260")
	-- NOTE: modern scp (>=9.0) speaks SFTP — the server needs the subsystem.
	makac.fs.write_file(d .. "/sshd_config", ([[
Port %d
ListenAddress 127.0.0.1
HostKey %s/hostkey
PidFile %s/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile %s/authorized_keys
StrictModes no
LogLevel VERBOSE
Subsystem sftp internal-sftp
]]):format(port, d, d, d))
	local proc = makac.spawn({ sshd, "-D", "-f", d .. "/sshd_config", "-E", d .. "/sshd.log" },
		{ stdout = d .. "/sshd.out", stderr = d .. "/sshd.err" })
	-- readiness: retry a real client auth until it works (max ~5s)
	local spec = {
		host = "127.0.0.1", user = os.getenv("USER") or "root", port = port,
		options = {
			IdentityFile = d .. "/id", BatchMode = "yes",
			StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null",
		},
	}
	local ready = false
	for _ = 1, 50 do
		local probe = makac.exec({ "ssh", "-i", d .. "/id", "-p", tostring(port),
			"-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=2",
			"127.0.0.1", "true" })
		if probe.code == 0 then ready = true break end
		makac.time.sleep(100 * makac.time.ns_per_ms)
	end
	if not ready then
		error("sshd never became ready:\n" ..
			(makac.fs.read_file(d .. "/sshd.log") or "") ..
			(makac.fs.read_file(d .. "/sshd.err") or ""))
	end
	local function cleanup()
		pcall(makac.exec, { "kill", tostring(proc.pid) })
	end
	return spec, cleanup
end

h.case("ssh_real", "real_run_put_get_multiplex_close", function(ctx)
	if not ssh_cases_enabled() or not (have("sshd") and have("ssh-keygen")) then
		print("# skip: sshd/ssh-keygen unavailable or MAKAC_TEST_SSH=0")
		return
	end
	local spec, cleanup = start_sshd(ctx)
	local proj = ssh_project(ctx)
	local speclit = ([[{ host = %q, user = %q, port = %d,
  options = { IdentityFile = %q, BatchMode = "yes", ConnectTimeout = "3",
              StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null" } }]])
		:format(spec.host, spec.user, spec.port, spec.options.IdentityFile)
	local ok, err = pcall(function()
		ctx.write("proj/real.txt", "real-roundtrip")
		ctx.mkdir_p("proj/dir/sub")
		ctx.write("proj/dir/sub/nested.txt", "nested-content")
		local r = wf(ctx, proj, nil, ([[
local spec = %s
local t = makac.new_ssh_target("realvm", spec)
local r1 = t:run({ "whoami" })
print("whoami: " .. r1.stdout:gsub("%%s+$", ""))
local r2 = t:run({ "printenv", "BB_REAL" }, { env = { BB_REAL = "over-the-wire" } })
print("env: " .. r2.stdout:gsub("%%s+$", ""))
local r3 = t:run({ "uname", "-s" })
print("uname: " .. r3.stdout:gsub("%%s+$", ""))
-- files: single and recursive directory, both directions
t:put(%q, "put-single.txt")
t:get("put-single.txt", %q)
t:put(%q, "put-dir")
t:get("put-dir/sub/nested.txt", %q)
-- session open: the state dir must now hold the control socket alongside
-- the generated config
local statedir = (tostring(makac.project_root(makac.data_dir)) .. "/.makac/targets/realvm")
local names = {}
for _, e in ipairs(makac.fs.listdir(statedir) or {}) do names[#names + 1] = e.name end
table.sort(names)
print("state files: " .. table.concat(names, ","))
t:close()
]])
			:format(speclit,
				ctx.path("proj/real.txt"),
				ctx.path("proj/got-single.txt"),
				ctx.path("proj/dir"),
				ctx.path("proj/got-nested.txt")))
		h.eq(r.code, 0, "workflow exit: " .. r.stderr)
		h.contains(r.stdout, "whoami: " .. spec.user, "run over real ssh")
		h.contains(r.stdout, "env: over-the-wire", "env wrapping over real ssh")
		h.contains(r.stdout, "uname: Linux", "real command execution")
		local nstated = select(2, r.stdout:gsub("state files: [^\\n]*", ""))
		h.eq(nstated, 1, "state files reported")
		local sf = r.stdout:match("state files: ([^\\n]*)") or ""
		h.truthy(sf:find(",", 1, true) ~= nil, "control socket beside the config (multiplexing): " .. sf)
	end)
	-- file assertions (even if the workflow failed, inspect what landed)
	if ok then
		h.eq(makac.fs.read_file(ctx.path("proj/got-single.txt")), "real-roundtrip", "put+get file roundtrip")
		h.eq(makac.fs.read_file(ctx.path("proj/got-nested.txt")), "nested-content", "recursive dir transfer")
	end
	cleanup()
	if not ok then error(err, 0) end
end)
