// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
package vm

import "core:c"
import "core:testing"

import lua "vendor:lua/5.4"

// The checked-in end-to-end example (examples/nvme_test/nvme_test.lua) is
// manual-acceptance only (it needs real QEMU/KVM and a guest image), but it
// must never silently bit-rot: it has to at least PARSE. Load-only — never
// executed — via luaL_loadbuffer, so syntax/reportable compile errors fail
// here (task: design2 wrap-up).

@(test)
test_example_nvme_test_parses :: proc(t: ^testing.T) {
	v := new()
	defer close(v)
	src := #load("../examples/nvme_test/nvme_test.lua", string)
	status := lua.L_loadbuffer(
		v.state,
		raw_data(src),
		c.size_t(len(src)),
		"@examples/nvme_test/nvme_test.lua",
	)
	if status != .OK {
		msg := _pop_error_message(v.state)
		defer delete(msg)
		testing.expectf(
			t,
			false,
			"examples/nvme_test/nvme_test.lua does not parse: %s",
			msg,
		)
	}
}
