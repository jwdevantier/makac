-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- makac embedded stdlib. Extends the VM with the workflow DSL.
-- Baked into the binary (see vm/prelude.odin) and evaluated once, before any
-- user-facing Lua, by vm.new().
--
-- Later tasks grow this into the real DSL (step, built-in actions, fact
-- finders, target wrappers, the pkgs/ module searcher).

-- `makac` may already exist: it holds the Odin-side primitives registered
-- before the prelude runs (e.g. makac.exec). Never overwrite it blindly.
makac = makac or {}

-- Registries: actions are callable step bodies (built-ins plus actions
-- contributed by fetched packages); fetchers populate .makac/packages/<id>.
-- action_default_names remembers each action's `default_name` for `step`.
makac.registry = { actions = {}, fetchers = {}, action_default_names = {} }

-- ==== Scoped cleanup (Lua 5.4 to-be-closed variables) ====
--
-- defer(fn) / errdefer(fn) return a to-be-closed value. Declare it with
-- `<close>` and Lua runs fn when the enclosing block exits:
--
--   local g <close> = makac.errdefer(function() release_thing() end)
--
--   makac.defer    -- on any scope exit (normal return or error)
--   makac.errdefer -- only when the scope exits via an error
--
-- Both are best-effort: an error from fn is reported on stderr, never
-- raised, so cleanup cannot mask the error that is unwinding. NOTE: the
-- `<close>` at the declaration site is load-bearing -- a plain local is
-- NOT closed, and the cleanup is then silently skipped.
local function scoped_cleanup(fn, error_only)
	assert(type(fn) == "function", "defer/errdefer: fn must be a function")
	return setmetatable({}, {
		__close = function(_, err)
			if error_only and err == nil then
				return
			end
			local ok, cleanup_err = pcall(fn, err)
			if not ok then
				io.stderr:write(("makac: deferred cleanup failed: %s\n"):format(
					tostring(cleanup_err)))
			end
		end,
	})
end

function makac.defer(fn)
	return scoped_cleanup(fn, false)
end

function makac.errdefer(fn)
	return scoped_cleanup(fn, true)
end

-- ==== Action machinery (design/action.md) ====

-- Register `fn` as action `name`; a step with `uses = "name"` invokes it.
-- `fn` receives the step's `with` table (nil if the step omits it) and
-- returns a result table, normalized by makac.run_action.
-- `opts.default_name`: remembered for `step`, used when a step omits `name`.
function makac.define_action(name, fn, opts)
	assert(type(name) == "string" and name ~= "",
		"makac.define_action: name must be a non-empty string")
	assert(type(fn) == "function",
		"makac.define_action: fn must be a function")
	if makac.registry.actions[name] then
		error(("makac.define_action: action '%s' is already defined"):format(name), 0)
	end
	makac.registry.actions[name] = fn
	if opts and opts.default_name then
		makac.registry.action_default_names[name] = opts.default_name
	end
end

-- Fill in the defaults of design/action.md's result shape so callers can
-- rely on every action result ALWAYS having that shape.
function makac.normalize_result(res)
	-- res.err: defaults to nil (absent) — set iff the action failed.
	if res.changed == nil then res.changed = false end
	if res.skipped == nil then res.skipped = false end
	if res.out == nil then res.out = {} end
	return res
end

-- Resolve `uses` in the action registry, invoke it with `with`, normalize
-- the result and return it. Unknown actions raise; so does an action whose
-- own code errors (with a message naming the action).
function makac.run_action(uses, with)
	assert(type(uses) == "string", "makac.run_action: uses must be a string")
	-- A '<pkg>:<action>' name resolves in the very same registry: package
	-- actions are merged into it under their full '<pkg>:<action>' key by
	-- makac.load_packages (splitting on the FIRST ':' and looking the rest
	-- up in the registry is exactly what that key lookup does — a name
	-- without ':' is a built-in). Unloaded/misspelled names just miss.
	local fn = makac.registry.actions[uses]
	if not fn then
		error(("makac: unknown action '%s' (no built-in action of that name; '<pkg>:<action>' names require the package to be fetched and loaded)"):format(uses), 0)
	end
	local ok, res = pcall(fn, with)
	if not ok then
		error(("makac: action '%s' failed: %s"):format(uses, tostring(res)), 0)
	end
	if type(res) ~= "table" then
		error(("makac: action '%s' returned %s, expected a result table"):format(uses, type(res)), 0)
	end
	return makac.normalize_result(res)
end

-- ==== Built-in actions ====

-- Trim trailing whitespace and cap a string at `limit` chars (for error
-- context snippets).
local function trim_snippet(s, limit)
	s = (s:gsub("%s+$", ""))
	if #s > limit then
		return s:sub(1, limit) .. " [...]"
	end
	return s
end

-- ==== Steps (design/steps.md) ====

-- ==== Step reporting (Ansible-esque progress, env-controlled ANSI) ====
--
-- Every step reports twice on stderr: when it STARTS and how it ENDED
-- (ok / changed / skipped / failed, with wall-clock elapsed time):
--
--    ▶ [host] image bootbase
--    changed: [host] image bootbase (41.3s)
--
-- Status colors (green ok / yellow changed / cyan skipped / red failed)
-- follow the usual conventions and need no flag parsing:
--   MAKAC_COLOR=never (or 0/false/no/off)     colors OFF
--   MAKAC_COLOR=always (or 1/true/yes/on)     colors ON, even if TERM says dumb
--   NO_COLOR (set to anything, convention)    colors OFF
--   default                                   ON, unless TERM is unset or 'dumb'
-- stderr keeps all of this off stdout, where the workflow's own output lives.
local _color_on = nil
local function step_colors_on()
	if _color_on ~= nil then return _color_on end
	local mc = os.getenv("MAKAC_COLOR")
	if mc ~= nil then
		mc = mc:lower()
		_color_on = (mc == "1" or mc == "true" or mc == "yes" or mc == "on" or mc == "always")
		return _color_on
	end
	if os.getenv("NO_COLOR") ~= nil then _color_on = false return false end
	local term = os.getenv("TERM")
	_color_on = term ~= nil and term ~= "" and term ~= "dumb"
	return _color_on
end

local CTRL = { reset = "\27[0m", bold = "\27[1m", dim = "\27[2m",
	green = "\27[32m", yellow = "\27[33m", cyan = "\27[36m", red = "\27[1;31m" }
local function paint(text, ...)
	if not step_colors_on() then return text end
	return table.concat({ ... }) .. text .. CTRL.reset
end

-- one report line: `<status>: [<target>] <name>` optionally with elapsed
local function step_report(kind, tname, name, elapsed_s)
	local line = ("%s: [%s] %s"):format(kind, tname, name)
	if elapsed_s ~= nil then
		line = line .. paint((" (%.1fs)"):format(elapsed_s), CTRL.dim)
	end
	local color = ({ ok = CTRL.green, changed = CTRL.yellow,
		skipped = CTRL.cyan, failed = CTRL.red, run = CTRL.bold })[kind]
	io.stderr:write(paint(line, color) .. "\n")
end

-- A step is a concrete instantiation of an action. `step { ... }` executes
-- IMMEDIATELY when evaluated (never deferred), so steps may sit inside plain
-- Lua control flow — the workflow decides which steps run, when, and how
-- often. It returns the action's (normalized) result table.
--
-- spec:
--   name  (optional) human-readable step name; defaults to the action's
--                    registered default_name, else the `uses` string itself
--   uses  (required) action reference: a built-in name ('shell', 'facts')
--                    or '<pkg>:<action>' for an action from a fetched package
--   with  (optional) arguments passed through to the action verbatim
--
-- Failure handling: an action reports failure in `result.err`; a failed step
-- aborts the workflow by raising an error naming the step, the action, and
-- the failure. Actions that treat a non-zero exit as data set no err (see
-- shell's with.ignore_exit_code).
function step(spec)
	assert(type(spec) == "table", "step: the step spec must be a table")
	assert(type(spec.uses) == "string" and spec.uses ~= "",
		"step: 'uses' is required and must be a string naming the action")
	if spec.name ~= nil then
		assert(type(spec.name) == "string", "step: 'name' must be a string")
	end
	if spec.with ~= nil then
		assert(type(spec.with) == "table",
			"step: 'with' must be a table of arguments for the action")
	end

	local with = spec.with
	if spec.target ~= nil then
		-- design/target.md: `target` is shorthand for `with.target`
		assert(makac.is_target(spec.target),
			"step: 'target' must be a target (e.g. makac.host or an action's out.target)")
		assert(with == nil or with.target == nil,
			"step: give the target either as spec.target or as with.target, not both")
		with = {}
		if spec.with then for k, v in pairs(spec.with) do with[k] = v end end
		with.target = spec.target
	end

	local name = spec.name
	if name == nil or name == "" then
		name = makac.registry.action_default_names[spec.uses] or spec.uses
	end

	-- progress: announce the step on stderr, prefixed with the ACTIVE
	-- target's name (the host when the step names no target)
	local tname = makac.host.name
	if with ~= nil and makac.is_target(with.target) then
		tname = with.target.name
	end
	step_report("run", tname, name)
	local started_ns = makac.time and makac.time.now and makac.time.now() or nil
	local function elapsed_s()
		if started_ns == nil then return nil end
		return (makac.time.now() - started_ns) / 1e9
	end

	local ok, res = pcall(makac.run_action, spec.uses, with)
	if not ok then
		step_report("failed", tname, name, elapsed_s())
		error(("step '%s' failed: %s"):format(name, tostring(res)), 0)
	end
	if res.err ~= nil then
		step_report("failed", tname, name, elapsed_s())
		error(("step '%s' (uses '%s') failed: %s"):format(name, spec.uses, tostring(res.err)), 0)
	end
	step_report(res.skipped and "skipped" or (res.changed and "changed" or "ok"),
		tname, name, elapsed_s())
	return res
end

-- Built-in `shell` action (design/action_shell.md): runs `with.cmd` on the
-- host by default, or on `with.target` when a target is given (design/target.md
-- "Relationship to steps").
local function shell_fn(with)
	with = with or {}
	assert(type(with.cmd) == "table",
		"makac.shell: 'with.cmd' is required and must be an array of strings")
	for i, arg in ipairs(with.cmd) do
		assert(type(arg) == "string",
			("makac.shell: 'with.cmd' must only contain strings (element %d is %s)"):format(i, type(arg)))
	end
	if with.env ~= nil then
		for k, v in pairs(with.env) do
			assert(type(k) == "string" and type(v) == "string",
				"makac.shell: 'with.env' must map string names to string values")
		end
	end

	-- design/action_shell.md, "The `shell` argument": `with.shell` is passed
	-- THROUGH to the target. Remote targets must do the `shell -c "<env>
	-- <argv>"` wrapping themselves (over SSH the command runs under the
	-- remote user's *login* shell — arbitrary, not necessarily POSIX — so a
	-- shell makac chose is invoked explicitly to interpret the env
	-- assignments). The host target ignores `shell`: locally there is no
	-- login shell in the way, the command is spawned directly and `env` is
	-- passed as a separate vector, so `shell` can have no effect.
	local target = makac.resolve_target(with)
	local res = target:run(with.cmd, {
		chdir = with.chdir,
		env = with.env,
		stdin = with.stdin,
		shell = with.shell,
		join = with.join,
		timeout_s = with.timeout_s,
		on_line = with.on_line,
	})

	local out = {
		stdout = res.stdout,
		stderr = res.stderr,
		-- lossy join of the two streams, for when a single string is
		-- more convenient (with join=true the stdout IS the true join;
		-- stderr comes back empty)
		output = res.stdout .. res.stderr,
		code = res.code,
		timed_out = res.timed_out or false,
	}
	local err
	if res.timed_out and not with.ignore_exit_code then
		err = ("command timed out after %s seconds: %s"):format(
			tostring(with.timeout_s), trim_snippet(res.stdout .. res.stderr, 200))
	elseif res.code ~= 0 and not with.ignore_exit_code then
		-- failing to *execute* (no capture) is surfaced by makac.exec; a
		-- non-zero exit is data, not an exec error (design/target.md)
		local context = res.stderr ~= "" and res.stderr or res.stdout
		err = ("command exited with code %d: %s"):format(res.code, trim_snippet(context, 200))
	end
	return { changed = true, err = err, out = out }
end

makac.define_action("shell", shell_fn, { default_name = "run shell command" })

-- Register `fn` as the built-in fetcher `name` (usable as `fetcher.name` in
-- packages.lua). Fetchers take the fetcher table from packages.lua and the
-- destination directory path: fetch(def, dest).
function makac.register_fetcher(name, fn)
	assert(type(name) == "string" and name ~= "",
		"makac.register_fetcher: name must be a non-empty string")
	assert(type(fn) == "function",
		"makac.register_fetcher: fn must be a function")
	if makac.registry.fetchers[name] then
		error(("makac.register_fetcher: fetcher '%s' is already registered"):format(name), 0)
	end
	makac.registry.fetchers[name] = fn
end

-- ==== Facts (design/facts.md) ====

-- Fact finders are small functions `function (target) return {...} end` that
-- run commands on a target and return an associative table of whatever they
-- want to expose. Built-ins are referred to by name in `with.finders`;
-- workflows may equally pass any function (e.g. imported from a package's
-- lib/ directory). A dedicated registry keeps finder names out of the action
-- registry.
makac.registry.fact_finders = {}

-- Register `fn` as the built-in fact finder `name` (usable as a string value
-- in the facts action's `with.finders`).
function makac.register_fact_finder(name, fn)
	assert(type(name) == "string" and name ~= "",
		"makac.register_fact_finder: name must be a non-empty string")
	assert(type(fn) == "function",
		"makac.register_fact_finder: fn must be a function")
	if makac.registry.fact_finders[name] then
		error(("makac.register_fact_finder: fact finder '%s' is already registered"):format(name), 0)
	end
	makac.registry.fact_finders[name] = fn
end

-- Built-in `facts` action: unlike Ansible, gathering facts is not an
-- obligatory phase — the workflow decides WHEN to collect facts (any step
-- may later alter them) and WHICH finders to run. `with.finders` maps a
-- namespace to a finder (built-in name string or function); each namespace
-- becomes a table under res.out.facts.<namespace>.
--
-- `with.target` selects the target to gather from (design/target.md); omitted
-- means the runner (host) itself.
local function facts_fn(with)
	with = with or {}
	local target = makac.resolve_target(with)
	assert(type(with.finders) == "table",
		"makac.facts: 'with.finders' is required and must map a namespace to a fact finder")

	local facts = {}
	for ns, finder in pairs(with.finders) do
		assert(type(ns) == "string" and ns ~= "",
			"makac.facts: finder namespaces (with.finders keys) must be non-empty strings")
		local fn
		if type(finder) == "string" then
			-- built-in finder by name
			fn = makac.registry.fact_finders[finder]
			if not fn then
				error(("makac.facts: unknown fact finder '%s' (namespace '%s')"):format(finder, ns), 0)
			end
		elseif type(finder) == "function" then
			-- custom/imported finder
			fn = finder
		else
			error(("makac.facts: finder for namespace '%s' must be a string (built-in finder) or a function, got %s"):format(ns, type(finder)), 0)
		end

		local ok, res = pcall(fn, target)
		if not ok then
			error(("makac.facts: fact finder for namespace '%s' failed: %s"):format(ns, tostring(res)), 0)
		end
		if type(res) ~= "table" then
			error(("makac.facts: fact finder for namespace '%s' returned %s, expected a table"):format(ns, type(res)), 0)
		end
		facts[ns] = res
	end
	return { changed = false, out = { facts = facts } }
end

makac.define_action("facts", facts_fn, { default_name = "gather facts" })

-- ==== Built-in fact finders ====

-- `os`: operating system and architecture of the target.
makac.register_fact_finder("os", function(target)
	target = target or makac.host
	local res = target:run({ "uname", "-s" })
	if res.code ~= 0 then
		error("fact finder 'os': 'uname -s' failed (exit " .. res.code .. ")", 0)
	end
	local os_name = (res.stdout:gsub("%s+$", "")):lower()
	res = target:run({ "uname", "-m" })
	if res.code ~= 0 then
		error("fact finder 'os': 'uname -m' failed (exit " .. res.code .. ")", 0)
	end
	local arch = (res.stdout:gsub("%s+$", ""))
	return { os = os_name, arch = arch }
end)

-- `env`: environment variables of the target, NAME -> value.
makac.register_fact_finder("env", function(target)
	target = target or makac.host
	local res = target:run({ "env" })
	if res.code ~= 0 then
		error("fact finder 'env': 'env' failed (exit " .. res.code .. ")", 0)
	end
	local env = {}
	for line in res.stdout:gmatch("[^\r\n]+") do
		-- values may contain '='; split on the FIRST one
		local name, value = line:match("^([^=]+)=(.*)$")
		if name then env[name] = value end
	end
	return env
end)

-- ==== Targets (design/target.md) ====

-- Live targets; the runner closes every one of them when the workflow
-- finishes (wired by the run command later). Closing is idempotent.
makac.registry.targets = {}

-- Whether `v` is a target. The kinds are fixed by makac — actions never
-- define new kinds, they only PRODUCE targets of existing kinds (e.g. a qemu
-- action returning a remote target in res.out.target).
function makac.is_target(v)
	return type(v) == "table"
		and (v.kind == "host" or v.kind == "remote")
		and type(v.run) == "function"
		and type(v.put) == "function"
		and type(v.get) == "function"
		and type(v.close) == "function"
end

-- Construct a target of `kind` named `name` from an ops table
--   { run = fn(self, argv, opts) -> {code=, stdout=, stderr=},
--     put = fn(self, src, dst), get = fn(self, src, dst),
--     close = fn(self) }           -- optional teardown
--
-- The wrapper enforces the uniform lifecycle (design/target.md): close() is
-- idempotent, and run/put/get on a closed target fail. Exposed so actions
-- from fetched packages (e.g. a VM provider) can produce remote targets.
function makac.make_target(kind, name, ops)
	assert(kind == "host" or kind == "remote",
		"makac.make_target: kind must be 'host' or 'remote' (target kinds are fixed)")
	assert(type(name) == "string" and name ~= "",
		"makac.make_target: name must be a non-empty string")
	assert(type(ops) == "table"
		and type(ops.run) == "function"
		and type(ops.put) == "function"
		and type(ops.get) == "function",
		"makac.make_target: ops must provide run, put and get functions")

	local t = { kind = kind, name = name, _closed = false }
	function t:_check_open(op)
		if self._closed then
			error(("makac: target '%s' is closed — %s is no longer allowed"):format(self.name, op), 0)
		end
	end
	function t:run(argv, opts)
		self:_check_open("run")
		return ops.run(self, argv, opts)
	end
	function t:put(src, dst)
		self:_check_open("put")
		return ops.put(self, src, dst)
	end
	function t:get(src, dst)
		self:_check_open("get")
		return ops.get(self, src, dst)
	end
	function t:close()
		if self._closed then return end -- idempotent
		self._closed = true
		if ops.close then ops.close(self) end
	end

	makac.registry.targets[#makac.registry.targets + 1] = t
	return t
end

-- Resolve a step/action's `with` table to the target it runs against:
-- `with.target` when given (it must be a real target), else the host.
function makac.resolve_target(with)
	local target = with ~= nil and with.target or nil
	if target == nil then
		return makac.host
	end
	assert(makac.is_target(target),
		"'with.target' must be a target (e.g. makac.host or an action's out.target)")
	return target
end

-- Construct a target from a PLAIN spec table:
--   makac.new_target {
--     kind  = "host" | "remote",
--     name  = "...",
--     run   = function(argv, opts) -> {code=, stdout=, stderr=},
--     put   = function(src, dst),   -- optional; errors "not supported" when absent
--     get   = function(src, dst),   -- optional; same
--     close = function(),           -- optional teardown
--   }
-- These are plain functions (no `self`): makac's uniform lifecycle wrapper
-- (makac.make_target) handles the target method calling convention,
-- idempotent close and closed-target checks.
function makac.new_target(spec)
	assert(type(spec) == "table", "makac.new_target: spec must be a table")
	assert(type(spec.run) == "function",
		"makac.new_target: spec.run must be a function (argv, opts) -> {code, stdout, stderr}")
	local ops = {}
	local function wrap(fname, present)
		if present then
			return function(_self, ...) return present(...) end
		end
		return function(self)
			error(("makac: target '%s' does not support %s"):format(self.name, fname), 0)
		end
	end
	ops.run = wrap("run", spec.run)
	ops.put = wrap("put", spec.put)
	ops.get = wrap("get", spec.get)
	ops.close = spec.close -- optional; make_target tolerates nil
	return makac.make_target(spec.kind, spec.name, ops)
end

-- Close every live target (design/target.md: "the runner closes every target
-- when the workflow finishes"). Called by the `run` command AFTER the
-- workflow has been evaluated — even when it failed (the Odin side invokes
-- this unconditionally). Best-effort per target: a failing close is warned
-- about on stderr, never raised (later targets still get closed). Reverse
-- order — later targets may stand on the shoulders of earlier ones.
function makac.close_all_targets()
	for i = #makac.registry.targets, 1, -1 do
		local t = makac.registry.targets[i]
		local ok, err = pcall(function() t:close() end)
		if not ok then
			io.stderr:write(("makac: warning: closing target '%s' failed: %s\n")
				:format(t.name, tostring(err)))
		end
	end
end

-- Resolve a target-side path for a host target: relative paths resolve
-- against the home directory (what scp does).
local function host_resolve(path)
	if path:sub(1, 1) == "/" then return path end
	local home = os.getenv("HOME")
	if not home or home == "" then
		error("makac: relative target path given but $HOME is not set", 0)
	end
	return home .. "/" .. path
end

-- The host target: the machine makac itself runs on. Always available and
-- used whenever a step/action does not name a target. run spawns the command
-- directly via makac.exec (non-zero exit is data, never an exec error — the
-- ops table returns code/stdout/stderr verbatim); put/get are plain copies;
-- close frees nothing.
makac.host = makac.make_target("host", "host", {
	run = function(_self, argv, opts)
		assert(type(argv) == "table",
			"target run: the command must be an array of strings (program followed by arguments)")
		assert(type(argv[1]) == "string" and argv[1] ~= "",
			"target run: argv[1] (the program) must be a non-empty string")
		for i, arg in ipairs(argv) do
			assert(type(arg) == "string",
				("target run: the command must only contain strings (element %d is %s)"):format(i, type(arg)))
		end
		opts = opts or {}
		-- chdir omitted: the directory makac was invoked from IS the host
		-- default (design/target.md), since exec inherits makac's own cwd
		return makac.exec(argv, {
			chdir = opts.chdir, env = opts.env, stdin = opts.stdin,
			join = opts.join, timeout_s = opts.timeout_s, on_line = opts.on_line,
		})
	end,
	put = function(self, src, dst)
		assert(type(src) == "string" and src ~= "", "put: src must be a host path")
		assert(type(dst) == "string" and dst ~= "", "put: dst must be a target path")
		dst = host_resolve(dst)
		local res = makac.exec({ "cp", "-R", src, dst })
		if res.code ~= 0 then
			error(("makac: put to '%s' failed: %s"):format(self.name, (res.stderr:gsub("%s+$", ""))), 0)
		end
	end,
	get = function(self, src, dst)
		assert(type(src) == "string" and src ~= "", "get: src must be a target path")
		assert(type(dst) == "string" and dst ~= "", "get: dst must be a host path")
		src = host_resolve(src)
		local res = makac.exec({ "cp", "-R", src, dst })
		if res.code ~= 0 then
			error(("makac: get from '%s' failed: %s"):format(self.name, (res.stderr:gsub("%s+$", ""))), 0)
		end
	end,
	close = function(_self) end, -- the host is always available; nothing to free
})

-- Shell-quote one word for POSIX sh: bare when safe, else single-quoted with
-- the standard ''' escape for embedded quotes. Used twice around a remote
-- command: once building the `shell -c "<...>"` script (shell action) and
-- once quoting that whole script for the outer login-shell transport (remote
-- target run).
function makac.shquote(word)
	word = tostring(word)
	if word ~= "" and word:match("^[%w@%_%%=:%.,%/%+%-]+$") then
		return word
	end
	return "'" .. word:gsub("'", "'\\''") .. "'"
end

-- Remote target reached over SSH (design/target.md):
--   makac.new_ssh_target(name, spec)
--   name     (required, positional) target identity: used in progress
--            reporting; also names its state dir <data_dir>/targets/<name>/
--            (so: [A-Za-z0-9._-])
--   spec.host     (required) hostname/IP
--   spec.user     (required) login user
--   spec.port     (optional) default 22
--   spec.options  (optional) extra OpenSSH options, e.g. { IdentityFile = "..." }
--                 (string keys -> string/number/bool values)
-- Backed by an SSH session object (makac.ssh_open): the generated ssh config
-- sets ControlMaster/ControlPath/ControlPersist under the session's own state
-- dir, so the first command authenticates and everything after multiplexes
-- over it. No connection happens at construction — only config generation.
function makac.new_ssh_target(name, spec)
	assert(type(name) == "string" and name ~= "",
		"makac.new_ssh_target: name must be a non-empty string")
	assert(type(spec) == "table", "makac.new_ssh_target: spec must be a table")
	assert(type(spec.host) == "string" and spec.host ~= "",
		"makac.new_ssh_target: spec.host must be a non-empty string")
	assert(type(spec.user) == "string" and spec.user ~= "",
		"makac.new_ssh_target: spec.user must be a non-empty string")
	local sess = makac.ssh_open(name, {
		host = spec.host, user = spec.user,
		port = spec.port, options = spec.options,
	})

	return makac.make_target("remote", name, {
		run = function(_self, argv, opts)
			assert(type(argv) == "table" and type(argv[1]) == "string" and argv[1] ~= "",
				"target run: the command must be an array of strings starting with the program")
			for i, arg in ipairs(argv) do
				assert(type(arg) == "string",
					("target run: the command must only contain strings (element %d is %s)"):format(i, type(arg)))
			end
			opts = opts or {}
			-- design/action_shell.md, "The `shell` argument": over SSH the
			-- command runs under the remote user's *login* shell — arbitrary
			-- (fish, zsh, ...), not necessarily POSIX — so when a shell was
			-- chosen (`opts.shell`, from the shell action) or env assignments
			-- are needed (`opts.env`, POSIX syntax a non-POSIX login shell
			-- might reject), invoke the chosen shell explicitly:
			-- `shell -c "<env assignments> <quoted argv>"`. The three words
			-- are then quoted again for the login-shell transport below.
			if opts.shell ~= nil or opts.env ~= nil then
				local shell = opts.shell or "/bin/sh"
				assert(type(shell) == "string" and shell:sub(1, 1) == "/",
					"target run: opts.shell must be an absolute path (e.g. '/bin/sh')")
				local sb = {}
				if opts.env ~= nil then
					local names = {}
					for k in pairs(opts.env) do names[#names + 1] = k end
					table.sort(names) -- deterministic command lines
					for _, k in ipairs(names) do
						assert(type(k) == "string" and k:match("^[%a_][%w_]*$"),
							("target run: opts.env: '%s' is not a valid variable name"):format(tostring(k)))
						sb[#sb + 1] = k .. "=" .. makac.shquote(opts.env[k])
					end
				end
				for _, arg in ipairs(argv) do sb[#sb + 1] = makac.shquote(arg) end
				argv = { shell, "-c", table.concat(sb, " ") }
			end
			-- assemble ONE command string for the remote login shell:
			-- `cd <chdir> && <quoted argv words>`; the default cwd is the
			-- account's home directory (where ssh runs commands anyway), so
			-- an absent chdir needs nothing.
			local words = {}
			if opts.chdir then
				assert(type(opts.chdir) == "string" and opts.chdir ~= "",
					"target run: opts.chdir must be a non-empty string")
				words[#words + 1] = "cd " .. makac.shquote(opts.chdir) .. " &&"
			end
			assert(opts.timeout_s == nil,
				"target run: opts.timeout_s is not supported on remote targets (yet)")
			assert(opts.on_line == nil,
				"target run: opts.on_line is not supported on remote targets (yet)")
			for _, arg in ipairs(argv) do words[#words + 1] = makac.shquote(arg) end
			-- join: there IS no separate stderr to be had over one ssh channel
			-- when asked to merge; redirect in the remote command line (2>&1)
			local cmdline = table.concat(words, " ")
			if opts.join then cmdline = cmdline .. " 2>&1" end
			return sess:run(cmdline, { stdin = opts.stdin })
		end,
		put = function(_self, src, dst)
			assert(type(src) == "string" and src ~= "", "put: src must be a host path")
			assert(type(dst) == "string" and dst ~= "", "put: dst must be a target path")
			sess:put(src, dst)
		end,
		get = function(_self, src, dst)
			assert(type(src) == "string" and src ~= "", "get: src must be a target path")
			assert(type(dst) == "string" and dst ~= "", "get: dst must be a host path")
			sess:get(src, dst)
		end,
		close = function(_self)
			sess:close()
		end,
	})
end

-- ==== Fetchers (design/fetchers.md) ====

-- Built-in `fetchurl` fetcher (design/fetchers.md): fetches over HTTP(S),
-- verifies the bytes against sha256, and unpacks into `dest`. Follows the
-- fetcher contract fn(spec, dest_dir) where spec is the FULL entry table from
-- packages.lua, so the fetcher's arguments are under spec.with:
--
--   with.url      (required) URL to fetch (http/https; anything curl can GET)
--   with.sha256   (required) 64 hex chars; verified after fetch — a mismatch
--                  is a hard error (see makac.download)
--   with.unpacker (required) "tar" to extract with the system tar, or a custom
--                  function(args, dst_dir) which receives the downloaded file
--                  path in args.archive
makac.register_fetcher("fetchurl", function(spec, dest)
	assert(type(spec) == "table", "fetchurl: expected the full package entry table")
	local pkgid = tostring(spec.id and spec.id or "<no id>")
	local args = spec.with
	if type(args) ~= "table" then
		error(("fetchurl: package '%s': requires a 'with' table { url = ..., sha256 = ..., unpacker = ... }"):format(pkgid), 0)
	end
	local url = args.url
	if type(url) ~= "string" or url == "" then
		error(("fetchurl: package '%s': 'with.url' must be a non-empty string"):format(pkgid), 0)
	end
	if type(dest) ~= "string" or dest == "" then
		error("fetchurl: 'dest' must be a non-empty path", 0)
	end

	-- sha256: required — the fetched bytes are always verified
	local sha256 = args.sha256
	if type(sha256) ~= "string" then
		error(("fetchurl: package '%s': 'with.sha256' (64 hex chars) is required; fetched %s must be verified"):format(pkgid, url), 0)
	end
	sha256 = sha256:lower()
	if #sha256 ~= 64 or not sha256:match("^[0-9a-f]+$") then
		error(("fetchurl: package '%s': invalid sha256 '%s' for '%s' (expected 64 hex characters)"):format(pkgid, tostring(args.sha256), url), 0)
	end

	-- unpacker: required; "tar" or a custom function
	local unpacker = args.unpacker
	if unpacker == nil then
		error(("fetchurl: package '%s': 'with.unpacker' is required: \"tar\" (extract with system tar) or a custom function(args, dst_dir)"):format(pkgid), 0)
	end
	if type(unpacker) ~= "function" and unpacker ~= "tar" then
		error(("fetchurl: package '%s': 'with.unpacker' must be \"tar\" or a function, got %s"):format(pkgid, tostring(unpacker)), 0)
	end

	-- download (cached under the data directory; verifies sha256 — a failing
	-- verification raises a clear checksum error via makac.download)
	local archive = makac.download(url, sha256)

	local res = makac.exec({ "mkdir", "-p", dest })
	if res.code ~= 0 then
		error(("fetchurl: failed to create package directory '%s': %s"):format(dest, res.stderr), 0)
	end

	if type(unpacker) == "function" then
		-- custom uncompressor: hand off with the downloaded file path
		-- injected into a copy of the with-args
		local uargs = { archive = archive }
		for k, v in pairs(args) do uargs[k] = v end
		local ok, err = pcall(unpacker, uargs, dest)
		if not ok then
			error(("fetchurl: package '%s': custom unpacker failed: %s"):format(pkgid, tostring(err)), 0)
		end
		return
	end

	-- "tar": extract the archive as-is (tar assumed on PATH)
	res = makac.exec({ "tar", "-xf", archive, "-C", dest })
	if res.code ~= 0 then
		error(("fetchurl: failed to extract tarball fetched from %s into '%s': %s"):format(url, dest, res.stderr), 0)
	end
end)

-- Built-in `fetchgit` fetcher (design/fetchers.md): fetches a package over
-- Git by shelling out to `git` (assumed on PATH). Follows the fetcher
-- contract fn(spec, dest_dir) where spec is the FULL entry table from
-- packages.lua; the fetcher's arguments are under spec.with:
--   with.url  (required) git URL to clone
--   with.rev  (optional) commit hash, tag, or branch to check out; without it
--              the repository's default branch is checked out
--
-- The clone KEEPS its .git directory: a later fetch into an existing work
-- tree fetches and re-checks-out instead of re-cloning, so `makac fetch` is
-- re-runnable. Unlike target run results (where a non-zero exit is data), a
-- non-zero git exit here is a fetch FAILURE and aborts the fetch run; git's
-- stderr is included in the error message.
makac.register_fetcher("fetchgit", function(spec, dest)
	assert(type(spec) == "table", "fetchgit: expected the full package entry table")
	local pkgid = tostring(spec.id and spec.id or "<no id>")
	local args = spec.with or {}
	local url = args.url
	if type(url) ~= "string" or url == "" then
		error(("fetchgit: package '%s': 'with.url' must be a non-empty string"):format(pkgid), 0)
	end
	local rev = args.rev
	if rev ~= nil and (type(rev) ~= "string" or rev == "") then
		error(("fetchgit: package '%s': 'with.rev' must be a non-empty string"):format(pkgid), 0)
	end
	if type(dest) ~= "string" or dest == "" then
		error("fetchgit: 'dest' must be a non-empty path", 0)
	end

	-- git env vars leaked from the caller's environment (e.g. a stray
	-- GIT_INDEX_FILE) must not leak into the subprocesses
	local git_prefix = { "env", "-u", "GIT_INDEX_FILE", "-u", "GIT_DIR",
		"-u", "GIT_WORK_TREE", "-u", "GIT_OBJECT_DIRECTORY", "git" }
	-- git_argv builds the argv for a git invocation (NOTE: table.unpack must
	-- be expanded fully — inside a table constructor, only the LAST expression
	-- yields all its values)
	local function git_argv(...)
		local argv = { table.unpack(git_prefix) }
		for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
		return argv
	end
	-- git_run shells out; a non-zero exit raises a fetch error with git's
	-- stderr. `what` describes the operation for the message.
	local function git_run(what, ...)
		local c = makac.exec(git_argv(...))
		if c.code ~= 0 then
			error(("fetchgit: %s failed for %s: %s"):format(what, url, c.stderr), 0)
		end
		return c
	end

	-- existing git work tree at dest? -> fetch + checkout instead of re-clone
	local probe = makac.exec(git_argv(
		"-C", dest, "rev-parse", "--is-inside-work-tree"))
	if probe.code == 0 and probe.stdout:gsub("%s+", "") == "true" then
		git_run("git fetch", "-C", dest, "fetch", "--tags", "origin")
		if rev then
			git_run(("git checkout %q"):format(rev), "-C", dest, "checkout", "--quiet", rev)
			-- a checked-out branch should track the freshly fetched tip; ignore
			-- failures (rev may be a tag or commit, which has no origin/<rev>)
			makac.exec(git_argv(
				"-C", dest, "merge", "--ff-only", "--quiet", "origin/" .. rev))
		end
		return
	end

	-- fresh clone straight into dest
	git_run("git clone", "clone", "--quiet", "--", url, dest)
	if rev then
		git_run(("git checkout %q"):format(rev), "-C", dest, "checkout", "--quiet", rev)
	end
end)

-- Built-in `filesystem` fetcher: the package LIVES AT 'with.path' on the
-- local filesystem and is used IN PLACE — nothing is copied anywhere (dest
-- is unused). This is the development fetcher: edit the package, rerun
-- 'makac run', no refetch needed.
--
-- Relative paths resolve against the project root (the directory holding
-- the .makac data dir), so workflows work from any subdirectory.
--
--   { id = "mypkg.dev", fetcher = "filesystem",
--     with = { path = "path/to/package" } }
--
-- 'Fetching' only validates: the path must be an existing directory with a
-- makac.lua at its root (design/packages.md) — a typo'd path is thus caught
-- by 'makac fetch', not later at run time. Loading reads from the path
-- itself (see makac.load_packages / makac.resolve_pkg_dir).
makac.register_fetcher("filesystem", function(spec, dest)
	assert(type(spec) == "table", "filesystem: expected the full package entry table")
	local pkgid = tostring(spec.id)
	local dir = makac.resolve_pkg_dir(spec) -- validates with.path
	if not makac.listdir(dir) then
		error(("filesystem: package '%s': path '%s' does not exist or is not a directory"):format(pkgid, dir), 0)
	end
	local f = io.open(dir .. "/makac.lua", "r")
	if not f then
		error(("filesystem: package '%s': no makac.lua at '%s' (a package must have one at its root, see design/packages.md)"):format(pkgid, dir), 0)
	end
	f:close()
	print(("using '%s' in place (nothing copied): %s"):format(pkgid, dir))
end)

-- ==== Package list (design/packages.md) ====

-- Read and validate <data_dir>/packages.lua. Returns an array of package
-- definition tables. Any violation of the format is a hard error naming the
-- offending entry index and key (design/packages.md):
--
--   return {
--     { id = "qemu",                  -- non-empty string, may not contain ':'
--       fetcher = "fetchgit",         -- string (fetcher name) OR a function
--       with = { url = "...", ... } },-- optional args table for the fetcher
--   }
function makac.read_package_defs(data_dir)
	data_dir = data_dir or makac.data_dir
	local path = data_dir .. "/packages.lua"
	local f = io.open(path, "r")
	if not f then
		error(("makac: no package list found at '%s'"):format(path), 0)
	end
	local src = f:read("a")
	f:close()

	-- the file is either a chunk returning a table or a bare table
	-- constructor; try as-is, then as an expression
	local chunk = load(src, "packages.lua")
	if not chunk then chunk = load("return\n" .. src, "packages.lua") end
	if not chunk then
		error(("makac: failed to parse '%s'"):format(path), 0)
	end
	local ok, defs = pcall(chunk)
	if not ok then
		error(("makac: failed to evaluate '%s': %s"):format(path, tostring(defs)), 0)
	end
	if type(defs) ~= "table" then
		error(("makac: packages.lua must return a table (an array of package entries; %s returned %s)"):format(path, type(defs)), 0)
	end

	local out = {}
	for i, def in ipairs(defs) do
		if type(def) ~= "table" then
			error(("makac: packages.lua entry #%d must be a table, got %s"):format(i, type(def)), 0)
		end
		local id = def.id
		if type(id) ~= "string" or id == "" then
			error(("makac: packages.lua entry #%d: 'id' must be a non-empty string"):format(i), 0)
		end
		-- ':' separates a package id from its action/fetcher/module names when
		-- referencing into a package, so ids may not contain it themselves
		if id:find(":", 1, true) then
			error(("makac: packages.lua entry #%d (id '%s'): 'id' must not contain ':'"):format(i, id), 0)
		end
		local ft = type(def.fetcher)
		if (ft ~= "string" and ft ~= "function") or (ft == "string" and def.fetcher == "") then
			error(("makac: packages.lua entry #%d (id '%s'): 'fetcher' must be a non-empty string (fetcher name, e.g. 'fetchgit' or 'fetchurl') or a function, got %s"):format(i, id, def.fetcher == "" and "empty string" or ft), 0)
		end
		if def.with ~= nil and type(def.with) ~= "table" then
			error(("makac: packages.lua entry #%d (id '%s'): 'with' must be a table of fetcher arguments, got %s"):format(i, id, type(def.with)), 0)
		end
		out[#out + 1] = def
	end
	return out
end

-- Resolve a package entry's fetcher to the fetcher function: a string names
-- a registered fetcher (built-in or contributed by an earlier package), a
-- function is used as-is.
function makac.resolve_fetcher(def)
	local fn = def.fetcher
	if type(fn) == "string" then
		fn = makac.registry.fetchers[fn]
		if not fn then
			error(("makac: package '%s': no known fetcher named '%s'"):format(def.id, def.fetcher), 0)
		end
	end
	return fn
end

-- Human-readable name of a package entry's fetcher (for progress/reporting).
function makac.fetcher_name(def)
	if type(def.fetcher) == "string" then return def.fetcher end
	return "<function>"
end

-- Where a package entry's code lives. Non-filesystem packages live where
-- 'makac fetch' put them: <data_dir>/packages/<id>/. A package with the
-- built-in 'filesystem' fetcher is used IN PLACE at with.path; a relative
-- path resolves against the project root (the directory containing the
-- .makac data dir), so the reference is stable no matter which subdirectory
-- a workflow runs from. Errors clearly when with.path is missing/invalid.
function makac.resolve_pkg_dir(def, data_dir)
	data_dir = data_dir or makac.data_dir
	assert(type(def) == "table" and type(def.id) == "string",
		"resolve_pkg_dir: expected a package definition table")
	if def.fetcher == "filesystem" then
		local path = def.with and def.with.path
		if type(path) ~= "string" or path == "" then
			error(("makac: package '%s': the 'filesystem' fetcher requires a non-empty 'with.path' (the package's directory on disk)"):format(def.id), 0)
		end
		if path:sub(1, 1) == "/" then return path end -- already absolute
		return data_dir .. "/../" .. path
	end
	return data_dir .. "/packages/" .. def.id
end

-- Pretty-print the package definitions from packages.lua (one line per
-- package: index, id, fetcher name).
function makac.print_package_defs(defs)
	if #defs == 0 then
		print("no packages defined.")
		return
	end
	print(("defined packages (#%d):"):format(#defs))
	for i, def in ipairs(defs) do
		print(("  %d. %s (fetcher: %s)"):format(i, def.id, makac.fetcher_name(def)))
	end
end

-- Fetch every package listed in <data_dir>/packages.lua into
-- <data_dir>/packages/<id>/ using its declared fetcher. Entries are fetched
-- IN FILE ORDER (design/packages.md: an earlier fetched package may provide
-- the fetcher for a later one). The fetcher registry is prepopulated with
-- the built-ins fetchurl/fetchgit; an unknown fetcher name is an error naming
-- the package id and the fetcher. Any fetch failure aborts the whole fetch
-- run (non-zero exit).
--
-- FUTURE (design/fetchers.md chaining): a package that is fetched and whose
-- makac.lua registers additional fetchers should become usable as the
-- fetcher for LATER entries in the same fetch run. Packages are only loaded
-- during 'makac run' for now (see load_packages) — fetch-during-fetch
-- chaining is not implemented yet.
function makac.fetch_all(data_dir)
	data_dir = data_dir or makac.data_dir
	local defs = makac.read_package_defs(data_dir)
	for _, def in ipairs(defs) do
		local dest = data_dir .. "/packages/" .. def.id
		local fetcher = makac.resolve_fetcher(def) -- errors if unknown
		print(("fetching %s via %s..."):format(def.id, makac.fetcher_name(def)))
		local ok, err = pcall(fetcher, def, dest)
		if not ok then
			error(("makac: fetch: package '%s': %s"):format(def.id, tostring(err)), 0)
		end
		print(("fetched %s"):format(def.id))
	end
	return #defs
end


-- ==== Packages: pkgs/ module loader + loading into the registries (design/packages.md) ====

-- Searcher for 'pkgs/<id>/<a>/<b>' module names: a loaded package's ./lib
-- directory is the root (design/packages.md), so 'pkgs/foo/a/b' maps to
-- <package root>/lib/a/b.lua ('/' separates, '.lua' is appended). The
-- package root comes from makac.pkg_dirs (see makac.load_packages):
-- .makac/packages/<id> for fetched packages, the source path itself for
-- filesystem-fetcher packages (edits are live — no refetch step). Unknown package ids and missing files contribute the standard
-- 'module not found' require error (returning a string from a searcher
-- appends it to require's error).
local function pkgs_searcher(modname)
	local id, rel = modname:match("^pkgs/([^/]+)/(.+)$")
	if not id then
		return nil -- not a pkgs/ module; defer to the other searchers
	end
	-- pkg_dirs maps each loaded package id to its code root (populated by
	-- makac.load_packages BEFORE running each package's makac.lua, so a
	-- package can require its own lib/ while loading).
	local pkg_dir = makac.pkg_dirs and makac.pkg_dirs[id]
	if not pkg_dir then
		return ("\n\tmakac: no loaded package '%s' (is it listed in packages.lua? 'makac run' / load_packages populates this)"):format(id)
	end
	local path = pkg_dir .. "/lib/" .. rel .. ".lua"
	local chunk = loadfile(path)
	if not chunk then
		return ("\n\tno file '%s'"):format(path)
	end
	return chunk
end
table.insert(package.searchers, pkgs_searcher)

-- makac.pkg_dirs[id] = the package's code root on disk (used by the pkgs/
-- module searcher). Populated by makac.load_packages: into
-- .makac/packages/<id>/ for fetched packages; the source path itself for
-- packages with the 'filesystem' fetcher (load-in-place development).
makac.pkg_dirs = makac.pkg_dirs or {}

-- Load every package listed in <data_dir>/packages.lua, IN FILE ORDER (the
-- list is authoritative: earlier packages may provide fetchers/actions that
-- later ones build on). For each entry the code root is resolved via
-- makac.resolve_pkg_dir: fetched packages come from
-- <data_dir>/packages/<id>/ (a listed-but-not-fetched package is a clear
-- error — run 'makac fetch'), while 'filesystem'-fetcher packages load in
-- place from with.path (no fetch step needed; the path must exist).
--
-- Each package's makac.lua runs in this VM and its exports merge into
-- makac's registries: `fetchers` and `actions` tables of name -> function,
-- each under the full key '<id>:<name>'. makac.pkg_dirs[<id>] is set BEFORE
-- makac.lua runs, so a package can require("pkgs/<own id>/...") its own
-- lib/ while loading. Missing makac.lua, non-function exports and name
-- collisions (checked against BOTH registries and any already-loaded
-- package) are errors naming the package. No packages.lua means no packages
-- — NOT an error (returns 0). Returns the number of packages loaded.
function makac.load_packages(data_dir)
	data_dir = data_dir or makac.data_dir
	if type(data_dir) ~= "string" or data_dir == "" then
		error("makac.load_packages: no data directory (makac.data_dir is unset)", 0)
	end
	local defs_file = io.open(data_dir .. "/packages.lua", "r")
	if not defs_file then return 0 end -- no package list: nothing to load
	defs_file:close()
	local defs = makac.read_package_defs(data_dir) -- validates, file order

	for _, def in ipairs(defs) do
		local id = def.id
		local dir = makac.resolve_pkg_dir(def, data_dir)
		if not makac.listdir(dir) then
			if def.fetcher == "filesystem" then
				error(("makac.load_packages: package '%s': filesystem path '%s' does not exist or is not a directory"):format(id, dir), 0)
			end
			error(("makac.load_packages: package '%s' is listed in packages.lua but nothing exists at '%s' -- run 'makac fetch' first"):format(id, dir), 0)
		end
		-- register the code root first: the package's own makac.lua may
		-- require its lib/ modules while loading
		makac.pkg_dirs[id] = dir

		local mpath = dir .. "/makac.lua"
		local chunk, lerr = loadfile(mpath)
		if not chunk then
			error(("makac.load_packages: package '%s': %s (a package must have a makac.lua at its root, see design/packages.md)"):format(id, tostring(lerr)), 0)
		end
		local ok, exports = pcall(chunk)
		if not ok then
			error(("makac.load_packages: package '%s': makac.lua failed: %s"):format(id, tostring(exports)), 0)
		end
		if exports == nil then exports = {} end
		if type(exports) ~= "table" then
			error(("makac.load_packages: package '%s': makac.lua must return a table of exports, got %s"):format(id, type(exports)), 0)
		end
		for kind, reg in pairs({ actions = makac.registry.actions, fetchers = makac.registry.fetchers }) do
			if exports[kind] ~= nil and type(exports[kind]) ~= "table" then
				error(("makac.load_packages: package '%s': exports.%s must be a table of name -> function, got %s"):format(id, kind, type(exports[kind])), 0)
			end
			for name, fn in pairs(exports[kind] or {}) do
				if type(fn) ~= "function" then
					error(("makac.load_packages: package '%s': %s '%s' must be a function, got %s"):format(id, kind, tostring(name), type(fn)), 0)
				end
				local full = id .. ":" .. tostring(name)
				-- the action and fetcher registries share one name space:
				-- reject collisions against either (and against what other,
				-- already-loaded packages contributed)
				if makac.registry.actions[full] or makac.registry.fetchers[full] then
					error(("makac.load_packages: package '%s': name '%s' collides with an existing action/fetcher"):format(id, full), 0)
				end
				reg[full] = fn
			end
		end
	end
	return #defs
end


-- ==== LuaLS stubs (design/luacats.md) ====

-- Install/refresh what lua-language-server needs to see makac's Lua API:
--   <data_dir>/makac.lua   the base stub (embedded in the binary)
--   <data_dir>/pkgs/<id>   -> <package root>/lib, so that
--                          require("pkgs/<id>/<rel>") resolves to source
-- and point the project's .luarc.json at the data dir as its single library
-- root. Idempotent and best-effort: a failure warns on stderr, never fails the
-- workflow (a broken install costs editor features, never a run).
function makac.luals_setup()
	local data_dir = makac.data_dir
	if type(data_dir) ~= "string" or data_dir == "" then
		return
	end
	local ok, err = pcall(function()
		-- One tree, under the data dir:
		--   <data>/makac.lua       the stub (makac, step, ...)
		--   <data>/pkgs/<id>  ->   <package>/lib    the require alias
		-- and ONE library root, the data dir itself. The alias and the code it
		-- points at are then under the SAME root, so LuaLS resolves the symlink
		-- to a single file and indexes it once. (Two roots exposing the same
		-- file is what produced duplicate definitions.)
		makac.fs.mkdir_p(data_dir .. "/pkgs")

		-- migration from the old <data>/luals layout (stub + mirror): remove the
		-- stale tree so it cannot be indexed a second time under the one root.
		if makac.fs.stat(data_dir .. "/luals") ~= nil then
			pcall(function() makac.fs.open_dir(data_dir):remove("luals") end)
		end

		local stub = makac.luals_stub
		if type(stub) == "string" and stub ~= "" then
			local stub_path = data_dir .. "/makac.lua"
			if makac.fs.read_file(stub_path) ~= stub then
				makac.fs.write_file(stub_path, stub, { atomic = true })
			end
		end

		-- alias targets come from the package DEFINITIONS, so this works
		-- straight after `makac fetch` without loading (running) any package.
		local okdefs, defs = pcall(makac.read_package_defs, data_dir)
		if okdefs and type(defs) == "table" then
			for _, def in ipairs(defs) do
				local okdir, root = pcall(makac.resolve_pkg_dir, def, data_dir)
				if okdir and type(root) == "string" and makac.fs.stat(root .. "/lib") ~= nil then
					makac.fs.symlink(root .. "/lib", data_dir .. "/pkgs/" .. def.id)
				end
			end
		end

		-- .luarc.json: makac owns `workspace.library` and points it at the one
		-- root, the data dir; every other key is preserved.
		local root_dir = data_dir:match("^(.*)/[^/]+$") or "."
		local name = data_dir:match("([^/]+)$") or ".makac"
		local entry = "./" .. name
		local luarc = root_dir .. "/.luarc.json"

		if makac.fs.stat(root_dir .. "/.luarc.jsonc") ~= nil then
			io.stderr:write(("makac: %s/.luarc.jsonc present; add %q to workspace.library yourself\n"):format(root_dir, entry))
			return
		end

		local raw = makac.fs.read_file(luarc)
		local cfg = {}
		if raw ~= nil then
			local pok, parsed = pcall(makac.json.loads, raw)
			if not pok or type(parsed) ~= "table" then
				io.stderr:write("makac: cannot parse " .. luarc .. "; leaving it untouched\n")
				return
			end
			cfg = parsed
		end
		cfg["workspace.library"] = { entry }
		local out = makac.json.dumps(cfg) .. "\n"
		if raw ~= out then
			makac.fs.write_file(luarc, out, { atomic = true })
		end
	end)
	if not ok then
		io.stderr:write("makac: warning: LuaLS stub install failed: " .. tostring(err) .. "\n")
	end
end