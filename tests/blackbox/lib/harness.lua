-- lib/harness.lua — tiny test framework for black-box testing a makac binary.
--
-- Deliberately minimal-footprint: uses only makac.exec + makac.fs + print, so
-- the Zig port can drive this harness very early in its life (that is itself
-- the first differential test — see tests/blackbox/README.md).
--
--   local h = require("harness")
--   h.suite("cli"); h.case("cli", "version", function(ctx) ... end)
--   ...then from the entry workflow: h.main(bin)

local M = {}

local suites = {}       -- ordered: { { name=..., cases={ {name=...,fn=...}, ... } } }
local suite_by_name = {}

function M.suite(name)
	assert(not suite_by_name[name], "duplicate suite: " .. name)
	local s = { name = name, cases = {} }
	suites[#suites + 1] = s
	suite_by_name[name] = s
end

function M.case(suite_name, name, fn)
	local s = assert(suite_by_name[suite_name], "unknown suite: " .. suite_name)
	s.cases[#s.cases + 1] = { name = name, fn = fn }
end

-- --- assertions -----------------------------------------------------------

local function q(v)
	if type(v) == "string" then return string.format("%q", v) end
	return tostring(v)
end

local function fail(what, extra)
	error((what or "assertion failed") .. (extra and ("\n  " .. extra) or ""), 2)
end

function M.eq(got, want, what)
	if got ~= want then
		fail(what or "values differ", ("got:  %s\n  want: %s"):format(q(got), q(want)))
	end
end

function M.contains(hay, needle, what)
	if type(hay) ~= "string" or not hay:find(needle, 1, true) then
		fail(what or "substring not found",
			("needle: %s\n  haystack: %s"):format(q(needle), q(hay)))
	end
end

function M.not_contains(hay, needle, what)
	if type(hay) == "string" and hay:find(needle, 1, true) then
		fail(what or "substring unexpectedly present",
			("needle: %s\n  haystack: %s"):format(q(needle), q(hay)))
	end
end

function M.matches(s, pat, what)
	if type(s) ~= "string" or not s:match(pat) then
		fail(what or "pattern did not match",
			("pattern: %s\n  text:    %s"):format(pat, q(s)))
	end
end

function M.truthy(v, what)
	if not v then fail(what or "expected truthy value", "got: " .. q(v)) end
end

--- Normalize nondeterministic bits of CLI output for comparison:
--- tmp paths -> <TMP>, step timings "(0.0s)" -> "(Ts)".
function M.norm(ctx, s)
	s = s:gsub(ctx.tmp:gsub("%W", "%%%0"), "<TMP>")
	s = s:gsub("%(%d+%.%d+s%)", "(Ts)")
	return s
end

-- --- test context -----------------------------------------------------------

--- Fresh per-test context: a throwaway tmp dir + helpers to invoke the binary
--- under test. The binary is always invoked with MAKAC_COLOR=never merged on
--- top of the current environment (deterministic stderr), with chdir
--- defaulting to the tmp dir (isolated: no .makac/.git anywhere above /tmp).
function M.new_ctx(bin)
	-- mktemp_dir returns a makac.path value; stringify once for concatenation
	local tmp = tostring(assert(makac.fs.mktemp_dir("makac-blackbox")))
	local ctx = { tmp = tmp, bin = bin }

	--- Run the binary under test. args: argv after the binary; opts:
	--- { chdir?, env?, stdin?, timeout_s? }. Returns { code, stdout, stderr, timed_out }.
	function ctx.run(args, opts)
		opts = opts or {}
		local argv = { bin }
		for _, a in ipairs(args) do argv[#argv + 1] = a end
		local env = { MAKAC_COLOR = "never" }
		if opts.env then for k, v in pairs(opts.env) do env[k] = v end end
		return makac.exec(argv, {
			chdir = opts.chdir or tmp,
			env = env,
			stdin = opts.stdin,
			timeout_s = opts.timeout_s,
		})
	end

	function ctx.path(rel) return tmp .. "/" .. rel end
	function ctx.write(rel, data) makac.fs.write_file(tmp .. "/" .. rel, data) end
	function ctx.read(rel) return makac.fs.read_file(tmp .. "/" .. rel) end
	function ctx.exists(rel) return makac.fs.stat(tmp .. "/" .. rel) ~= nil end
	function ctx.mkdir_p(rel) makac.fs.mkdir_p(tmp .. "/" .. rel) end

	local function cleanup()
		pcall(makac.exec, { "rm", "-rf", tmp })
	end
	return ctx, cleanup
end

-- --- runner -----------------------------------------------------------------

-- Quarantine list (same idea as tests/api): comma-separated <suite>/<case>
-- ids skipped for implementations with a KNOWN divergence (see
-- docs/findings.md). Reported as 'skip', never silenced.
local function skip_set()
	local s = {}
	for id in (os.getenv("MAKAC_BB_SKIP") or ""):gmatch("[^,]+") do s[id] = true end
	return s
end

function M.main(bin)
	local skip = skip_set()
	local pass, fail_n, skipped = 0, 0, 0
	for _, s in ipairs(suites) do
		print("# suite: " .. s.name)
		for _, c in ipairs(s.cases) do
			local id = s.name .. "/" .. c.name
			if skip[id] then
				skipped = skipped + 1
				print("skip " .. id .. " (quarantined: diverges on this implementation)")
			elseif true then
			local ctx, cleanup = M.new_ctx(bin)
			local ok, err = pcall(c.fn, ctx)
			cleanup()
			if ok then
				pass = pass + 1
				print("ok " .. id)
			else
				fail_n = fail_n + 1
				print("not ok " .. id)
				for line in tostring(err):gmatch("[^\n]+") do
					print("  | " .. line)
				end
			end
			end
		end
	end
	print(("# %d passed, %d failed, %d skipped"):format(pass, fail_n, skipped))
	if fail_n > 0 then os.exit(1) end
end

return M
