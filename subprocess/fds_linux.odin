// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// Close_FDs_Above, Linux implementation (see subprocess.odin for the
// portable contract).
#+build linux
package subprocess

import "core:sys/linux"
import "core:sys/posix"

// Fast path: one close_range(2) syscall (mainline since kernel 5.9, 2020)
// wipes the whole range; `keep` (the exec-status pipe's write end during a
// Run) is excluded by splitting the range around it. Invoked through the
// raw syscall number rather than the libc symbol so the package also links
// against musl and pre-2.34 glibc, which do not provide close_range(3).
//
// A kernel predating the syscall answers ENOSYS — close the hard way then.
Close_FDs_Above :: proc "contextless" (keep: posix.FD) {
	lo := u32(3)
	if keep > 2 {
		_ = linux.syscall(linux.SYS_close_range, u32(3), u32(keep - 1), 0)
		lo = u32(keep + 1)
	}
	r := linux.syscall(linux.SYS_close_range, lo, ~u32(0), 0)
	if r < 0 && -r == int(linux.Errno.ENOSYS) {
		_close_fds_loop(keep)
	}
}
