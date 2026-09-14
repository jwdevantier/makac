// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"

import lua "vendor:lua/5.4"

// makac.random_hex (design/stdlib.md, "Misc (flat)") — the one primitive
// that does not fit under a submodule; Ruby's SecureRandom.hex. Covers
// images.md's "generate an instance id" without shelling out to uuidgen.

register_random_primitives :: proc(v: ^VM) {
	register(v, "random_hex", _makac_random_hex)
}

// makac.random_hex(n) -> string — exactly n lowercase hex chars drawn from
// core:crypto's CSPRNG. ODD n works: ceil(n/2) bytes, hex-encode (2n chars
// per byte), truncate to n. n <= 0 RAISES per the "argument misuse, not
// syscall result" convention (pid_alive precedent in vm/proc.odin).
//
// crypto.rand_bytes fills via the Linux getrandom syscall, so there is no
// allocation-free shortcut anyway; use a temp-allocator buffer.
@(private = "file")
_makac_random_hex :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	n := lua.L_checkinteger(L, 1)
	if n <= 0 {
		return c.int(lua.L_error(L, "makac: random_hex: n must be positive (got %d)", i64(n)))
	}
	nbytes := int(n + 1) / 2
	buf := make([]byte, nbytes, context.temp_allocator)
	crypto.rand_bytes(buf)
	h, herr := hex.encode(buf, context.temp_allocator)
	if herr != nil {
		errmsg := fmt.tprintf("hex encode failed: %v", herr)
		return c.int(lua.L_error(L, "makac: random_hex: %s", cstring(raw_data(errmsg))))
	}
	out := h[:n]
	lua.pushlstring(L, cstring(raw_data(out)), c.size_t(len(out)))
	return 1
}
