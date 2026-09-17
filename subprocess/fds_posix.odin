// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// Close_FDs_Above, portable POSIX implementation (see subprocess.odin for
// the contract). Linux builds take the close_range(2) fast path instead
// (fds_linux.odin).
#+build !linux
package subprocess

import "core:sys/posix"

Close_FDs_Above :: proc "contextless" (keep: posix.FD) {
	_close_fds_loop(keep)
}
