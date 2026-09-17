// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
//
// subprocess — capture stdout/stderr from a child process, with optional
// timeout, per-line streaming callback, and PATH-aware executable lookup.
//
// Three callers share this single implementation:
//   - `vm.exec_capture`        — full feature set: capture, timeout, on_line,
//                                stdin, working_dir, env, join_stderr.
//   - `downloader.run_capture` — capture only stderr (curl writes the body
//                                to a file); no timeout, no on_line.
//   - `ssh.run_process`        — capture nothing; the parent's stdio is
//                                passed through for interactive sessions.
//
// Run owns its fork/exec (it does not use os.process_start): the child is
// placed in its own process group whenever a kill path exists, so timeout
// and callback-abort escalation reach grandchildren, and it closes every
// inherited file descriptor above 2 before exec (Close_FDs_Above) so QMP
// sockets and SSH control sockets cannot leak into unrelated children.
//
// `Find_Executable` is the PATH resolver with the execute-bit check that
// `vm.spawn._resolve_exec_path` previously skipped.
package subprocess

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

// Result is the outcome of `Run`. `stdout` and `stderr` are populated when
// the corresponding `Options.capture_*` is true; otherwise they are empty.
//
// `stdout` and `stderr` are slices into a single contiguous allocation owned
// by the caller (allocated with `Options.allocator`) — the caller frees
// `stdout` once to release both buffers. The slices alias each other when
// `Options.join_stderr` is true.
//
// `timed_out` is true iff the deadline was reached and the child was killed.
// `callback_aborted` is true iff the `on_line` callback returned false.
// A child killed by the escalation is reported with `code` = the signal
// number (matching core:os's wait reporting for killed children); the two
// flags above carry the "why".
//
// A non-zero `code` is data, not an error: only a spawn failure sets
// the returned `os.Error`.
Result :: struct {
	code:             int,
	stdout:           []byte,
	stderr:           []byte,
	timed_out:        bool,
	callback_aborted: bool,
}

// Line_Callback is invoked once per complete line as data arrives, before
// the captured buffer exists. `stream` is "stdout" or "stderr". Return
// false to abort the child — the run completes with `callback_aborted`
// set and the child SIGTERM/KILL'd. `ctx` round-trips caller state.
Line_Callback :: proc "c" (ctx: rawptr, stream, line: string) -> bool

// Options controls `Run` behavior. Zero value = capture stdout+stderr with no
// timeout, no on_line, inherit working dir + env, allocator from context.
Options :: struct {
	// working_dir, when non-empty, becomes the child's cwd.
	working_dir: string,
	// env, when non-nil, is the child's WHOLE environment — and its PATH=
	// entry (when present) is what an unqualified argv[0] is resolved
	// against, unlike os.process_start which always consulted the parent's
	// PATH. nil inherits the parent's environment verbatim.
	env: []string,
	// stdin_data, when present, is written to the child's stdin (then closed).
	stdin_data: Maybe(string),
	// stdin_fd, when set (and no stdin_data), becomes the child's fd 0.
	// Neither option wires the child to /dev/null.
	stdin_fd: Maybe(^os.File),

	// Stdout wiring, in order: capture_stdout = true → a pipe, captured
	// into Result.stdout. Else stdout_fd set → the child's fd 1 IS that
	// file (no pipe at all — interactive passthrough). Else → a pipe that
	// is read and DISCARDED, so a chatty child cannot block on a full
	// pipe. Stderr is symmetric (capture_stderr/stderr_fd), except that
	// join_stderr routes it onto whatever fd 1 is.
	capture_stdout: bool,
	capture_stderr: bool,
	stdout_fd:      Maybe(^os.File),
	stderr_fd:      Maybe(^os.File),

	// join_stderr makes stderr write into stdout's pipe — one stream, true
	// interleaved order (the shell's `2>&1`). Implies capture_stderr=false.
	join_stderr: bool,

	// timeout_s (> 0 = armed): on expiry the child's whole process group
	// is SIGTERM'd, given a 1s grace, then SIGKILL'd. `Result.timed_out`
	// is set.
	timeout_s: f64,

	// on_line, when set, streams complete lines as they arrive.
	on_line:     Line_Callback,
	on_line_ctx: rawptr,

	// allocator owns the captured output and the per-line streaming buffers.
	allocator: runtime.Allocator,
}

// ---------------------------------------------------------------------------
// Child-side fd hygiene
// ---------------------------------------------------------------------------

// Close_FDs_Above closes every file descriptor greater than 2 except `keep`
// (pass a negative value to keep nothing). It exists to run INSIDE a child
// between fork and exec: children must not inherit makac's long-lived
// descriptors (QMP sockets, SSH control sockets, capture pipes of other
// runs) — an inherited write end keeps pipes alive past their owners, and a
// daemonized descendant of an unrelated child can hold a QMP socket open
// after makac closed its own copy.
//
// POSIX's only portable primitive is the blunt one: close(2) on every
// number up to the soft RLIMIT_NOFILE (an EBADF for numbers that were not
// open is harmless). The Linux build takes the close_range(2) fast path
// (fds_linux.odin) because a million-close walk costs ~100 ms per spawn on
// the 1M soft limits modern systemd distributions ship; everywhere else
// `_close_fds_loop` below IS the implementation, and typical soft limits
// there keep it well under a millisecond.
//
// Post-fork discipline: no allocation, no Odin runtime — close(2) only.
// (The symbol itself lives in fds_linux.odin / fds_posix.odin, selected by
// the #+build tags; both forward to or wrap `_close_fds_loop` below.)

// The portable walk: 3 ..< soft RLIMIT_NOFILE, skipping `keep`. An
// RLIM_INFINITY soft limit (never seen in practice) is capped so the loop
// stays finite; a failing getrlimit falls back to the classic default.
_close_fds_loop :: proc "contextless" (keep: posix.FD) {
	limit := 1024
	rl: posix.rlimit
	if posix.getrlimit(.NOFILE, &rl) == .OK {
		cur := i64(rl.rlim_cur)
		if cur > 0 && cur != i64(~u64(0)) {
			limit = int(min(cur, i64(1 << 20)))
		}
	}
	for fd := 3; fd < limit; fd += 1 {
		if posix.FD(fd) == keep {continue}
		_ = posix.close(posix.FD(fd))
	}
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

Line_Feeder :: struct {
	cb:      Line_Callback,
	ctx:     rawptr,
	stopped: bool,
}

// Run `argv` to completion and return its Result.
//
// Spawn failure (empty argv, unresolvable executable, pipe/fork failure, or
// a pre-exec failure reported by the child through the status pipe) sets the
// returned `os.Error`; the Result is zero. A non-zero exit code is data.
//
// The child runs in its own process group iff a kill path exists
// (timeout_s > 0 or on_line set), so that the escalation's SIGTERM/SIGKILL
// — delivered to the group — also reaches grandchildren the child forked
// (a `sh -c "sleep 30 & wait"` step must not orphan its sleep). Without a
// kill path the child stays in makac's group: the terminal's Ctrl-C keeps
// reaching interactive ssh/scp children.
Run :: proc(argv: []string, opts: Options = {}) -> (res: Result, err: os.Error) {
	capture_out := opts.capture_stdout
	capture_err := opts.capture_stderr && !opts.join_stderr
	group := opts.timeout_s > 0 || opts.on_line != nil

	if len(argv) == 0 || len(argv[0]) == 0 {
		err = os.Platform_Error(.EINVAL)
		return
	}

	temp := context.temp_allocator

	// Resolve the executable PARENT-side: the child must make no
	// allocations, and an env PATH= entry must govern unqualified
	// commands (execvp semantics for an explicit environment).
	exe, found := Find_Executable(argv[0], opts.env, temp, temp)
	if !found {
		// Errno precision for path literals: present-but-not-executable
		// is EACCES, everything else is ENOENT.
		e := posix.Errno.ENOENT
		if strings.index_byte(argv[0], '/') >= 0 {
			if info, serr := os.stat(argv[0], temp); serr == nil {
				e = .EACCES
				os.file_info_delete(info, temp)
			}
		}
		err = os.Platform_Error(e)
		return
	}

	// Marshal every exec argument now: after fork the child performs
	// syscalls only (allocator state across a fork is not to be trusted).
	cargv := make([]cstring, len(argv) + 1, temp)
	for a, i in argv {
		cargv[i] = strings.clone_to_cstring(a, temp)
	}
	cargv[len(argv)] = nil
	cexe := strings.clone_to_cstring(exe, temp)

	cenvp: []cstring
	if opts.env != nil {
		cenvp = make([]cstring, len(opts.env) + 1, temp)
		for e, i in opts.env {
			cenvp[i] = strings.clone_to_cstring(e, temp)
		}
		cenvp[len(opts.env)] = nil
	}
	ccwd: cstring
	if opts.working_dir != "" {
		ccwd = strings.clone_to_cstring(opts.working_dir, temp)
	}

	// fd 1 target: a captured pipe, a passthrough file, or a drained pipe.
	stdout_r, stdout_w: ^os.File
	child_out: posix.FD
	if f, ok := opts.stdout_fd.?; ok && !capture_out {
		child_out = posix.FD(i32(os.fd(f)))
	} else {
		stdout_r, stdout_w = os.pipe() or_return
		child_out = posix.FD(i32(os.fd(stdout_w)))
	}
	defer if stdout_r != nil {os.close(stdout_r)}
	defer if stdout_w != nil {os.close(stdout_w)}

	// fd 2 target: stderr's own pipe/file, or fd 1's target when joined.
	stderr_r, stderr_w: ^os.File
	child_err: posix.FD
	if opts.join_stderr {
		child_err = child_out
	} else if f, ok := opts.stderr_fd.?; ok && !capture_err {
		child_err = posix.FD(i32(os.fd(f)))
	} else {
		stderr_r, stderr_w = os.pipe() or_return
		child_err = posix.FD(i32(os.fd(stderr_w)))
	}
	defer if stderr_r != nil {os.close(stderr_r)}
	defer if stderr_w != nil {os.close(stderr_w)}

	// fd 0 target: the stdin-data pipe, a passthrough file, or /dev/null
	// (opened child-side below).
	stdin_r, stdin_w: ^os.File
	child_in: posix.FD = -1
	if data, ok := opts.stdin_data.?; ok && len(data) > 0 {
		stdin_r, stdin_w = os.pipe() or_return
		child_in = posix.FD(i32(os.fd(stdin_r)))
	} else if f, ok := opts.stdin_fd.?; ok {
		child_in = posix.FD(i32(os.fd(f)))
	}
	defer if stdin_r != nil {os.close(stdin_r)}
	defer if stdin_w != nil {os.close(stdin_w)}

	// Exec-status pipe: the child writes one errno byte when anything
	// fails before execve; FD_CLOEXEC on the write end makes a SUCCESSFUL
	// exec close it, so the parent's read returns EOF exactly when the
	// child is running.
	status: [2]posix.FD
	if posix.pipe(&status) != .OK {
		err = os.Platform_Error(posix.errno())
		return
	}
	status_r, status_w := status[0], status[1]
	defer _ = posix.close(status_r)
	defer if status_w >= 0 { _ = posix.close(status_w) }
	_ = posix.fcntl(status_w, .SETFD, posix.FD_CLOEXEC)

	pid := posix.fork()
	if pid < 0 {
		err = os.Platform_Error(posix.errno())
		return
	}

	if pid == 0 {
		// CHILD — post-fork discipline: syscalls only, nothing that
		// touches the allocator (makac is threaded; the forked child
		// owns none of the other threads' state).
		fail :: proc "contextless" (w: posix.FD, e: c.int) {
			b := [1]u8{u8(e)}
			_ = posix.write(w, &b[0], 1)
			posix._exit(127)
		}

		if group && posix.setpgid(0, 0) != .OK {
			fail(status_w, c.int(posix.errno()))
		}

		fd_in := child_in
		if fd_in == -1 {
			fd_in = posix.open("/dev/null", posix.O_Flags{})
			if fd_in == -1 {fail(status_w, c.int(posix.errno()))}
		}
		if posix.dup2(fd_in, 0) < 0 {fail(status_w, c.int(posix.errno()))}
		if posix.dup2(child_out, 1) < 0 {fail(status_w, c.int(posix.errno()))}
		if posix.dup2(child_err, 2) < 0 {fail(status_w, c.int(posix.errno()))}

		// The status pipe must sit above the stdio slots to survive the
		// close below. It only could not when the parent itself ran with
		// closed stdio (a pipe landed on 0/1/2, and the dup2s clobbered
		// it); report exec failure the only way left — exit 127, no byte.
		if status_w < 3 {posix._exit(127)}

		// No inherited fd survives exec — not QMP sockets, not SSH
		// control sockets, not another run's pipes.
		Close_FDs_Above(status_w)

		if ccwd != nil {
			if posix.chdir(ccwd) != .OK {fail(status_w, c.int(posix.errno()))}
		}

		if cenvp != nil {
			_ = posix.execve(cexe, &cargv[0], &cenvp[0])
		} else {
			_ = posix.execve(cexe, &cargv[0], posix.environ)
		}
		fail(status_w, c.int(posix.errno()))
	}

	// PARENT — the child holds its own copies of the write ends; drop ours
	// RIGHT NOW so the read ends see EOF at child exit. (We can't defer
	// these to function exit — the poll loop below would never see EOF.)
	_ = posix.close(status_w)
	status_w = -1
	if stdout_w != nil {
		os.close(stdout_w)
		stdout_w = nil
	}
	if stderr_w != nil {
		os.close(stderr_w)
		stderr_w = nil
	}

	// Close the kill race: if the child has not run its setpgid yet, do it
	// for it. EACCES just means the child got there first. This must
	// happen before the first group kill, which it does — the deadline is
	// armed and the poll loop starts only after the status read below.
	if group {
		_ = posix.setpgid(pid, pid)
	}

	// Blocking wait for the exec outcome: EOF = the child is running; one
	// byte = the errno that stopped it before execve.
	exec_err: [1]u8
	n: c.ssize_t = -1
	for {
		n = posix.read(status_r, &exec_err[0], 1)
		if n >= 0 {break}
		if posix.errno() != .EINTR {break} // protocol broken; waitpid decides
	}
	if n == 1 {
		st: c.int
		for posix.waitpid(pid, &st, {}) < 0 && posix.errno() == .EINTR {}
		err = os.Platform_Error(posix.Errno(int(exec_err[0])))
		return
	}

	if data, ok := opts.stdin_data.?; ok && len(data) > 0 {
		rest := transmute([]u8)data
		for len(rest) > 0 {
			n, werr := os.write(stdin_w, rest)
			if werr != nil {break}
			rest = rest[n:]
		}
		// close promptly (not at function exit): the child's stdin must
		// see EOF once the data is through
		os.close(stdin_w)
		stdin_w = nil
	}

	stdout_b := make([dynamic]u8, opts.allocator)
	stderr_b := make([dynamic]u8, opts.allocator)
	buf: [4096]u8 = ---
	stdout_done := stdout_r == nil
	stderr_done := stderr_r == nil

	fdr := Line_Feeder{cb = opts.on_line, ctx = opts.on_line_ctx}
	out_line := make([dynamic]u8, context.temp_allocator)
	err_line := make([dynamic]u8, context.temp_allocator)

	feed :: proc(acc: ^[dynamic]u8, chunk: []u8, stream: string, fdr: ^Line_Feeder) {
		if fdr.cb == nil || fdr.stopped {return}
		append(acc, ..chunk)
		start := 0
		for i in 0 ..< len(acc) {
			if acc[i] != '\n' {continue}
			if !fdr.cb(fdr.ctx, stream, string(acc[start:i])) {
				fdr.stopped = true
				clear(acc)
				return
			}
			start = i + 1
		}
		copy(acc[:], acc[start:])
		resize(acc, len(acc) - start)
	}
	flush :: proc(acc: ^[dynamic]u8, stream: string, fdr: ^Line_Feeder) {
		if fdr.cb == nil || fdr.stopped || len(acc) == 0 {return}
		if !fdr.cb(fdr.ctx, stream, string(acc[:])) {fdr.stopped = true}
		clear(acc)
	}

	escalation := 0
	timed := opts.timeout_s > 0
	deadline := time.time_add(time.now(), time.Duration(opts.timeout_s * 1e9))

	// Escalation targets the child's GROUP when one exists, so grandchildren
	// forked by the child (a step's `sh -c "sleep 30 & wait"`) die with it
	// instead of outliving the run while holding inherited pipe write ends.
	kill_target := pid
	if group {
		kill_target = -pid
	}

	posix_fd :: #force_inline proc(f: ^os.File) -> posix.FD {return posix.FD(i32(os.fd(f)))}

	read_one :: proc(
		fd: ^os.File,
		accum, line_acc: ^[dynamic]u8,
		stream: string,
		readbuf: []u8,
		fdr: ^Line_Feeder,
		keep: bool,
	) -> (done: bool, rerr: os.Error) {
		n, r := os.read(fd, readbuf)
		switch r {
		case nil:
			if n > 0 {
				if keep {
					append(accum, ..readbuf[:n])
					feed(line_acc, readbuf[:n], stream, fdr)
				}
			}
			return false, nil
		case .EOF, .Broken_Pipe:
			flush(line_acc, stream, fdr)
			return true, nil
		case:
			return true, r
		}
	}

	for !stdout_done || !stderr_done {
		fds: [2]posix.pollfd
		nfds := 0
		if !stdout_done {fds[nfds] = {fd = posix_fd(stdout_r), events = {.IN}}; nfds += 1}
		if !stderr_done {fds[nfds] = {fd = posix_fd(stderr_r), events = {.IN}}; nfds += 1}

		ms := i32(-1)
		if timed {
			rem := time.duration_milliseconds(time.diff(time.now(), deadline))
			ms = rem > 0 ? i32(rem) : 0
		}
		n := posix.poll(&fds[0], auto_cast nfds, ms)
		if n < 0 {
			if posix.errno() == .EINTR {continue}
			res.stdout = stdout_b[:]
			res.stderr = stderr_b[:]
			err = os.Platform_Error(posix.errno())
			return
		}
		if n == 0 {
			switch escalation {
			case 0:
				res.timed_out = true
				_ = posix.kill(kill_target, .SIGTERM)
				deadline = time.time_add(time.now(), time.Second)
				escalation = 1
			case:
				_ = posix.kill(kill_target, .SIGKILL)
				timed = false
				escalation = 2
			}
			continue
		}

		wi := 0
		if !stdout_done {
			pfd := &fds[0]
			if .IN in pfd.revents {
				stdout_done, _ = read_one(stdout_r, &stdout_b, &out_line, "stdout", buf[:], &fdr, capture_out)
			} else if pfd.revents & {.HUP, .ERR, .NVAL} != {} {
				flush(&out_line, "stdout", &fdr)
				stdout_done = true
			}
			wi = 1
		}
		if !stderr_done {
			pfd := &fds[wi]
			if .IN in pfd.revents {
				stderr_done, _ = read_one(stderr_r, &stderr_b, &err_line, "stderr", buf[:], &fdr, capture_err)
			} else if pfd.revents & {.HUP, .ERR, .NVAL} != {} {
				flush(&err_line, "stderr", &fdr)
				stderr_done = true
			}
		}

		if fdr.stopped {
			res.callback_aborted = true
			_ = posix.kill(kill_target, .SIGTERM)
			_ = posix.kill(kill_target, .SIGKILL)
			timed = false
		}
	}

	st: c.int
	for {
		w := posix.waitpid(pid, &st, {})
		if w >= 0 {break}
		if posix.errno() != .EINTR {
			res.stdout = stdout_b[:]
			res.stderr = stderr_b[:]
			err = os.Platform_Error(posix.errno())
			return
		}
	}

	if posix.WIFEXITED(st) {
		res.code = int(posix.WEXITSTATUS(st))
	} else if posix.WIFSIGNALED(st) {
		// The signal number as the code, matching how core:os reports
		// killed children; timed_out / callback_aborted carry the reason.
		res.code = int(posix.WTERMSIG(st))
	} else {
		res.code = -1
	}
	res.stdout = stdout_b[:]
	res.stderr = stderr_b[:]
	return
}

// ---------------------------------------------------------------------------
// Find_Executable
// ---------------------------------------------------------------------------

// Find_Executable locates the absolute path of an executable and returns it.
// If `file` contains `/`, it is treated as a path literal: the candidate is
// accepted when it is a regular file with the user-execute bit set, matching
// how Odin's own PATH lookup behaves; otherwise `found` is false.
//
// If `file` has no `/`, the `PATH=` entry of `env` (if non-nil and non-empty)
// is consulted, otherwise the parent process's PATH. Each candidate is
// accepted under the same regular+execute-bit rule.
//
// The returned `resolved` is allocated from `out_alloc` when freshly looked
// up, or aliases `file` when `file` already names a path. The caller must
// `delete(resolved, out_alloc)` once it is done. The bookkeeping allocations
// made on `temp` are released by `Find_Executable` itself.
Find_Executable :: proc(
	file: string,
	env: []string,
	out_alloc, temp: runtime.Allocator,
) -> (resolved: string, found: bool) {
	if len(file) == 0 {
		return
	}

	if strings.index_byte(file, '/') >= 0 {
		info, err := os.stat(file, temp)
		if err == nil {
			ok := info.type == .Regular && .Execute_User in info.mode
			os.file_info_delete(info, temp)
			if ok {
				return file, true
			}
		}
		return file, false
	}

	// Resolve PATH: prefer the env override, fall back to the parent's PATH.
	path_value := ""
	if env != nil {
		for e in env {
			if len(e) >= 5 && e[:5] == "PATH=" {
				path_value = e[5:]
				break
			}
		}
	}
	if path_value == "" {
		path_value, _ = os.lookup_env("PATH", temp)
	}
	if path_value == "" {
		return
	}

	remaining := path_value
	for part in strings.split_iterator(&remaining, ":") {
		if len(part) == 0 {
			continue
		}
		path_len := len(part) + 1 + len(file)
		candidate, alloc_err := make([]u8, path_len, out_alloc)
		if alloc_err != nil {
			return
		}
		copy(candidate, part)
		candidate[len(part)] = '/'
		copy(candidate[len(part) + 1:], file)
		candidate_str := string(candidate)

		info, stat_err := os.stat(candidate_str, temp)
		if stat_err == nil {
			ok := info.type == .Regular && .Execute_User in info.mode
			os.file_info_delete(info, temp)
			if ok {
				return candidate_str, true
			}
		}
		delete(candidate, out_alloc)
	}
	return
}
