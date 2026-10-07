#!/usr/bin/env makac
-- tests/api/run.lua — in-VM conformance suite for the makac API.
--
--   <binary-under-test> run tests/api/run.lua
--
-- Runs INSIDE the VM of the binary under test: one process pins the return
-- shapes, error semantics and edge cases of every documented makac.* entry
-- point (the expanded API the typestubs and prelude offer). Complements
-- tests/blackbox/, which asserts CLI-observable behavior. See README.md.

package.path = SCRIPT_DIR .. "/lib/?.lua;" .. SCRIPT_DIR .. "/specs/?.lua;" .. package.path

local api = require("api")

require("surface")
require("exec_spawn")
require("fs")
require("pathdir")
require("json_time_env")
require("prelude")
require("project")

api.main()
