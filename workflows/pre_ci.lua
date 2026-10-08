#!/usr/bin/env makac
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- workflows/pre_ci.lua — the fast checks to run locally before pushing, so a
-- CI runner is not the first place a failure is seen:
--
--   makac run workflows/pre_ci.lua
--
--   1. formatting   — `zig fmt --check` over src/, build.zig, build.zig.zon.
--                      --check edits nothing: a non-zero exit means at least
--                      one file would be reformatted (the list is printed).
--   2. license lint — REUSE compliance, via scripts/reuse-check.sh.
--   3. docs site    — `mdbook build site`.
--
-- Each step runs through the flake dev shell that owns its tool, so the pinned
-- versions are used no matter what is on PATH. A failing step prints all of
-- its captured output and aborts the workflow.

-- The workflow lives in <root>/workflows/; fall back to the project root or
-- the working directory if it is invoked from somewhere else.
local root = SCRIPT_DIR:match("^(.*)/workflows$") or PROJECT_DIR or tostring(makac.fs.cwd())

--- Run argv on the host; print all captured output and abort on non-zero.
---@param name string
---@param argv string[]
local function run(name, argv)
	local r = step {
		name = name,
		uses = "shell",
		with = { cmd = argv, ignore_exit_code = true },
	}
	local out = r.out or {}
	local code = out.code or 0
	if code == 0 then
		return
	end
	local stdout = ((out.stdout or ""):gsub("%s+$", ""))
	local stderr = ((out.stderr or ""):gsub("%s+$", ""))
	if stdout ~= "" then io.stdout:write(stdout, "\n") end
	if stderr ~= "" then io.stderr:write(stderr, "\n") end
	error(("%s: failed (exit %d)"):format(name, code), 0)
end

-- 1. formatting (nothing is written; --check only reports).
run("zig fmt --check", {
	"nix", "develop", root, "--command", "zig", "fmt", "--check",
	root .. "/src", root .. "/build.zig", root .. "/build.zig.zon",
})

-- 2. license compliance (the script selects the flake's `lint` dev shell).
run("reuse lint (REUSE compliance)", { root .. "/scripts/reuse-check.sh" })

-- 3. documentation site.
run("mdbook build site", {
	"nix", "develop", root .. "#site", "--command", "mdbook", "build", root .. "/site",
})

print("pre-ci: all checks passed")
