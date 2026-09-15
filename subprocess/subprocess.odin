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
//   - `ssh.run_process`        — capture nothing (interactive ssh/scp);
//                                uses the parent's stdin/stdout/stderr.
//
// `Find_Executable` is the PATH resolver with the execute-bit check that
// `vm.spawn._resolve_exec_path` previously skipped.
package subprocess

import "base:runtime"
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
	// env, when non-nil, is the child's WHOLE environment. nil inherits.
	env: []string,
	// stdin_data, when present, is written to the child's stdin (then closed).
	stdin_data: Maybe(string),

	// When capture_stdout is false, the child's stdout is wired to
	// `stdout_fd` if set, else `os.stdout`. Same for stderr.
	capture_stdout: bool,
	capture_stderr: bool,
	stdout_fd:      Maybe(^os.File),
	stderr_fd:      Maybe(^os.File),

	// join_stderr makes stderr write into stdout's pipe — one stream, true
	// interleaved order (the shell's `2>&1`). Implies capture_stderr=false.
	join_stderr: bool,

	// timeout_s (> 0 = armed): on expiry the child is SIGTERM'd, given a
	// 1s grace, then SIGKILL'd. `Result.timed_out` is set.
	timeout_s: f64,

	// on_line, when set, streams complete lines as they arrive.
	on_line:     Line_Callback,
	on_line_ctx: rawptr,

	// allocator owns the captured output and the per-line streaming buffers.
	allocator: runtime.Allocator,
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
// Spawn failure sets the returned `os.Error`; the Result is zero. A
// non-zero exit code is data.
Run :: proc(argv: []string, opts: Options = {}) -> (res: Result, err: os.Error) {
	// join_stderr implies capture_stderr=false (the stderr text lands in
	// the stdout pipe and is returned via `Result.stdout`).
	capture_out := opts.capture_stdout
	capture_err := opts.capture_stderr && !opts.join_stderr

	// Always create pipes for stdout/stderr (the child writes to them via
	// os.process_start). When capture_* is false, the read end is drained
	// silently — bytes are discarded, no allocation grows.
	stdout_r, stdout_w := os.pipe() or_return
	defer os.close(stdout_r)
	stderr_r, stderr_w := os.pipe() or_return
	defer os.close(stderr_r)

	// join_stderr: route the child's stderr into stdout's pipe (2>&1).
	child_stderr_w := stderr_w
	if opts.join_stderr {
		child_stderr_w = stdout_w
	}

	stdin_r, stdin_w: ^os.File
	if data, ok := opts.stdin_data.?; ok && len(data) > 0 {
		stdin_r, stdin_w = os.pipe() or_return
	}
	defer if stdin_r != nil {os.close(stdin_r)}

	p, perr := os.process_start(os.Process_Desc{
		working_dir = opts.working_dir,
		command     = argv,
		env         = opts.env,
		stdin       = stdin_r,
		stdout      = stdout_w,
		stderr      = child_stderr_w,
	})
	if perr != nil {
		if stdin_w != nil {os.close(stdin_w)}
		err = perr
		return
	}

	// The child holds its own copies of the write ends; drop the parent's
	// RIGHT NOW so the read ends see EOF at child exit. (We can't defer
	// these to function exit — the poll loop below would never see EOF.)
	os.close(stdout_w)
	stdout_w = nil
	if !opts.join_stderr {
		os.close(stderr_w)
		stderr_w = nil
	}

	if data, ok := opts.stdin_data.?; ok && len(data) > 0 {
		defer os.close(stdin_w)
		rest := transmute([]u8)data
		for len(rest) > 0 {
			n, werr := os.write(stdin_w, rest)
			if werr != nil {break}
			rest = rest[n:]
		}
	}

	stdout_b := make([dynamic]u8, opts.allocator)
	stderr_b := make([dynamic]u8, opts.allocator)
	buf: [4096]u8 = ---
	stdout_done := !capture_out
	stderr_done := !capture_err

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

	posix_fd :: #force_inline proc(f: ^os.File) -> posix.FD {return posix.FD(i32(os.fd(f)))}

	read_one :: proc(
		fd: ^os.File,
		accum, line_acc: ^[dynamic]u8,
		stream: string,
		readbuf: []u8,
		fdr: ^Line_Feeder,
	) -> (done: bool, rerr: os.Error) {
		n, r := os.read(fd, readbuf)
		switch r {
		case nil:
			if n > 0 {
				append(accum, ..readbuf[:n])
				feed(line_acc, readbuf[:n], stream, fdr)
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
			res.stdout = stdout_b[:]
			res.stderr = stderr_b[:]
			err = os.Platform_Error(posix.errno())
			return
		}
		if n == 0 {
			switch escalation {
			case 0:
				res.timed_out = true
				_ = os.process_terminate(p)
				deadline = time.time_add(time.now(), time.Second)
				escalation = 1
			case:
				_ = os.process_kill(p)
				timed = false
				escalation = 2
			}
			continue
		}

		wi := 0
		if !stdout_done {
			pfd := &fds[0]
			if .IN in pfd.revents {
				stdout_done, _ = read_one(stdout_r, &stdout_b, &out_line, "stdout", buf[:], &fdr)
			} else if pfd.revents & {.HUP, .ERR, .NVAL} != {} {
				flush(&out_line, "stdout", &fdr)
				stdout_done = true
			}
			wi = 1
		}
		if !stderr_done {
			pfd := &fds[wi]
			if .IN in pfd.revents {
				stderr_done, _ = read_one(stderr_r, &stderr_b, &err_line, "stderr", buf[:], &fdr)
			} else if pfd.revents & {.HUP, .ERR, .NVAL} != {} {
				flush(&err_line, "stderr", &fdr)
				stderr_done = true
			}
		}

		if fdr.stopped {
			res.callback_aborted = true
			_ = os.process_terminate(p)
			_ = os.process_kill(p)
			timed = false
		}
	}

	state, werr := os.process_wait(p)
	if werr != nil {
		res.stdout = stdout_b[:]
		res.stderr = stderr_b[:]
		err = werr
		return
	}

	res.code = state.exit_code
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
