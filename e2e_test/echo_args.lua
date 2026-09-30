-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- Resource for e2e_test/script-args.sh: echoes the makac script context
-- (arg table, SCRIPT_DIR, PROJECT_DIR) in a stable format the test
-- compares byte-for-byte.

print("script:   " .. tostring(arg and arg[0]))
print("args (" .. tostring(arg and #arg or 0) .. "):")
for i = 1, #(arg or {}) do
	print(("  [%d] %q"):format(i, arg[i]))
end
print("SCRIPT_DIR:  " .. tostring(SCRIPT_DIR))
print("PROJECT_DIR: " .. tostring(PROJECT_DIR))
