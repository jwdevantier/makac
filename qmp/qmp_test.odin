// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package qmp

import "core:sys/posix"
import "core:testing"
import "core:time"

// A failed connect must not touch the process's stdin: teardown closes an fd
// only when the transport recorded one at connect time.

@(test)
test_failed_connect_leaves_stdin_open :: proc(t: ^testing.T) {
	before := posix.fcntl(0, .GETFL)
	if !testing.expectf(t, before != -1, "stdin (fd 0) is not open in this environment; the check below needs a live fd 0") {
		return
	}

	tr: Transport
	if !testing.expect(t, unix_transport(&tr, "/nonexistent-qmp-test.socket"), "unix_transport must accept a well-formed path") {
		return
	}
	client, cerr := connect_transport(tr, 1 * time.Second)
	if !testing.expect(t, cerr != .None, "connect to a nonexistent socket must fail") {
		close(&client)
		return
	}

	after := posix.fcntl(0, .GETFL)
	testing.expect(t, after != -1, "stdin (fd 0) was closed by a failed QMP connect")
	testing.expect(t, after == before, "stdin (fd 0) changed flags across a failed QMP connect")
}
