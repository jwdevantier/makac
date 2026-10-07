#!/usr/bin/env makac
-- tests/blackbox/run.lua — black-box test suite driving a makac binary.
--
--   makac tests/blackbox/run.lua [binary-under-test]
--
-- binary-under-test: path (default: "makac" resolved via PATH). Everything
-- is hermetic: each case gets a throwaway tmp dir; no network. See README.md.

package.path = SCRIPT_DIR .. "/lib/?.lua;" .. SCRIPT_DIR .. "/cases/?.lua;" .. package.path

local harness = require("harness")

-- resolve a bare command name via PATH to an absolute path, so the binary
-- under test is deterministic regardless of the cases' working directories.
local function resolve(bin)
	if bin:find("/", 1, true) then return bin end
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
