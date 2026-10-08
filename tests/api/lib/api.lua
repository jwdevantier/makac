-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- lib/api.lua — in-VM conformance framework for the makac API.
--
-- Runs INSIDE the binary under test ('makac run tests/api/run.lua'), so a
-- single process pins the return shapes, error semantics and edge cases of
-- every documented makac.* entry point. Complements tests/blackbox (which
-- asserts observable CLI behavior across process spawns).

local M = {}

local groups = {}        -- ordered: { { name=..., cases={ {name=..., fn=...} } } }
local group_by_name = {}

function M.group(name)
	assert(not group_by_name[name], "duplicate group: " .. name)
	local g = { name = name, cases = {} }
	groups[#groups + 1] = g
	group_by_name[name] = g
end

function M.t(group, name, fn)
	local g = assert(group_by_name[group], "unknown group: " .. group)
	g.cases[#g.cases + 1] = { name = name, fn = fn }
end

-- --- assertions -------------------------------------------------------------

local function q(v)
	if type(v) == "string" then return string.format("%q", v) end
	return tostring(v)
end

local function fail(what, extra)
	error((what or "assertion failed") .. (extra and ("\n  " .. extra) or ""), 3)
end

function M.eq(got, want, what)
	if got ~= want then
		fail(what or "values differ", ("got:  %s\n  want: %s"):format(q(got), q(want)))
	end
end

function M.neq(got, unwanted, what)
	if got == unwanted then fail(what or "value should differ", "got: " .. q(got)) end
end

function M.type_is(v, t, what)
	if type(v) ~= t then
		fail(what or ("expected type " .. t), ("got: %s (%s)"):format(q(v), type(v)))
	end
end

function M.contains(hay, needle, what)
	if type(hay) ~= "string" or not hay:find(needle, 1, true) then
		fail(what or "substring not found", ("needle: %s\n  haystack: %s"):format(q(needle), q(hay)))
	end
end

function M.matches(s, pat, what)
	if type(s) ~= "string" or not s:match(pat) then
		fail(what or "pattern did not match", ("pattern: %s\n  text:    %s"):format(pat, q(s)))
	end
end

function M.truthy(v, what)
	if not v then fail(what or "expected truthy value", "got: " .. q(v)) end
end

--- fn must raise; pat (optional) is a PLAIN substring the error must contain.
function M.raises(fn, pat, what)
	local ok, err = pcall(fn)
	if ok then fail(what or "expected an error, but call succeeded") end
	if pat then
		-- error messages carry '<file>:<line>:' prefixes; match in the tail
		if not tostring(err):find(pat, 1, true) then
			fail(what or "error message mismatch",
				("wanted substring: %s\n  got: %s"):format(q(pat), q(tostring(err))))
		end
	end
	return err
end

-- --- fixtures ---------------------------------------------------------------

--- Create (and return the path of) a fresh directory under the run's tmp root.
function M.dir(rel)
	local p = M.root .. "/" .. rel
	makac.fs.mkdir_p(p)
	return p
end

-- --- runner -----------------------------------------------------------------

-- Quarantine: comma-separated list of <group>/<case> ids that may hard-CRASH
-- the process (so pcall cannot contain them) on a given implementation.
-- Used to keep the suite runnable against the Odin reference where a case
-- pins a bug we are fixing in the Zig port (see docs/findings.md). Reported
-- as 'skip', never silently dropped.
local function skip_set()
	local s = {}
	for id in (os.getenv("MAKAC_API_SKIP") or ""):gmatch("[^,]+") do s[id] = true end
	return s
end

function M.main()
	M.root = tostring(assert(makac.fs.mktemp_dir("makac-api")))
	local skip = skip_set()
	local pass, fail_n, skipped = 0, 0, 0
	for _, g in ipairs(groups) do
		print("# group: " .. g.name)
		for _, c in ipairs(g.cases) do
			local id = g.name .. "/" .. c.name
			if skip[id] then
				skipped = skipped + 1
				print("skip " .. id .. " (quarantined: crashes this implementation)")
			else
				local ok, err = pcall(c.fn)
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
	pcall(makac.exec, { "rm", "-rf", M.root })
	if fail_n > 0 then os.exit(1) end
end

return M
