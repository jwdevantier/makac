// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "base:runtime"
import "core:c"
import "core:sys/posix"

import lua "vendor:lua/5.4"

// Process primitives (design2/stdlib.md, "Processes (flat — orchestrator
// vocabulary)") — flat under makac.*, not a submodule. `pid_alive` lives
// here; `spawn` joins this file in its own task. (`makac.exec`, the
// captured-stdout sibling, lives in vm/exec.odin.)

register_proc_primitives :: proc(v: ^VM) {
	register(v, "pid_alive", _makac_pid_alive)
}

// makac.pid_alive(pid) -> bool — ONE kill(pid, 0) syscall. `false` for
// ESRCH (no such pid), `true` for EPERM (the process exists even when it
// is not ours — shelling out to `kill -0` cannot tell the two apart
// without stderr parsing), `true` on success. NEVER raises: the answer is
// a boolean, not an exception (handle.md's up/down probe and vm.md's
// shutdown wait poll this until it flips).
@(private = "file")
_makac_pid_alive :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	// L_checkinteger raises on non-numeric args — bad argument types are
	// argument misuse, not a syscall result, and raise per convention.
	pid := posix.pid_t(lua.L_checkinteger(L, 1))
	if posix.kill(pid, .NONE) == .OK {
		lua.pushboolean(L, true)
		return 1
	}
	lua.pushboolean(L, b32(posix.errno() != .ESRCH))
	return 1
}
