#!/usr/bin/env makac
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- tests/blackbox/run.lua — black-box test suite driving a makac binary.
--
--   makac tests/blackbox/run.lua [binary-under-test]
--
-- binary-under-test: path (default: "makac" resolved via PATH). Everything
-- is hermetic: each case gets a throwaway tmp dir; no network. See README.md.

package.path = SCRIPT_DIR .. "/lib/?.lua;" .. SCRIPT_DIR .. "/cases/?.lua;" .. package.path

local harness = require("harness")

-- resolve the binary under test to an absolute path, so it stays valid
-- regardless of the per-case working directory: ctx.run chdir's the child to
-- a throwaway tmp dir, and a relative argv[0] would otherwise be resolved
-- against THAT directory (both the reference and the port exec a relative
-- path after chdir).
local function resolve(bin)
	if bin:find("/", 1, true) then
		if bin:sub(1, 1) == "/" then return bin end
		local pwd = (makac.exec({ "pwd" }).stdout or ""):gsub("%s+$", "")
		if pwd == "" then error("cannot determine cwd to resolve binary: " .. bin) end
		return pwd .. "/" .. bin
	end
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = dir .. "/" .. bin
		local st = makac.fs.stat(p) -- lstat: accept plain files and symlinks
		if st and (st.type == "file" or st.type == "link") then return p end
	end
	error("binary not found on PATH: " .. bin)
end

local binarg = arg[1]
if binarg == "--" then binarg = arg[2] end -- tolerate a stray separator
local bin = resolve(binarg or os.getenv("MAKAC_BIN") or "makac")
print("# testing: " .. bin)

require("cli")
require("datadir")
require("steps")
require("shellaction")
require("facts")
require("primitives")
require("packages")
require("ssh")
require("qmp")
require("download")

harness.main(bin)
