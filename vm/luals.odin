// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:c"

import lua "vendor:lua/5.4"

// The LuaCATS stub for makac's injected globals and stdlib (design/luacats.md),
// embedded in the binary like the prelude so the types always match the
// running version — no separate artifact to install or pin. The prelude's
// makac.luals_setup reads it back from makac._luals_stub and writes it into a
// project's data directory.
Luals_Stub :: #load("../luals/makac.lua", string)

// expose_luals_stub publishes the embedded stub as makac._luals_stub. Called
// after the prelude, so the makac table already exists.
expose_luals_stub :: proc(v: ^VM) {
	L := v.state
	lua.getglobal(L, "makac")
	lua.pushlstring(L, cstring(raw_data(Luals_Stub)), c.size_t(len(Luals_Stub)))
	lua.setfield(L, -2, "_luals_stub")
	lua.pop(L, 1)
}
