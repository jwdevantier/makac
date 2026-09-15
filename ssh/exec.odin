// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause

/*
exec - ssh / scp process runners.

These procedures shell out to the system `ssh` and `scp` binaries,
passing the config file written by `generate_config` via `-F`:

  * `execute_ssh` -- `ssh -F <config> -p <port> localhost [command]`;
    an empty `command` opens an interactive session, otherwise the
    command string is passed as a single argument to be run by the
    remote shell.

  * `scp_put` -- `scp -F <config> -P <port> [-r] <local> localhost:<remote>`;
    upload a file or directory to the VM.

  * `scp_get` -- `scp -F <config> -P <port> [-r] localhost:<remote> <local>`;
    download a file or directory from the VM.

Note the different port flags: lowercase `-p` for ssh, capital `-P`
for scp.

The child's stdin/stdout/stderr are wired to the parent's standard
streams by default, so interactive sessions and password prompts work.

Connection multiplexing is the point of this design: the config
enables ControlMaster/ControlPath/ControlPersist (from the option
tables written by `generate_config`), so the first invocation
establishes an authenticated master connection that is kept alive,
and every later invocation -- including scp transfers -- multiplexes
through it instead of re-authenticating.

All failures are reported through values (`Error`; `.kind == .None`
means success), not panics. Nothing inside an `Error` is allocated,
so there is nothing to free.
*/
package ssh

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import sp "../subprocess"

/// run_process starts `command` with `args` and waits for it to exit.
///
/// The child's standard streams are wired to `stdin`, `stdout` and
/// `stderr` (the parent's standard streams by default), so
/// interactive sessions and password prompts work. The child inherits
/// the parent's environment unless `child_env` is non-nil, in which
/// case it is used verbatim as the child's whole environment -- which
/// is primarily useful for testing, where a stub directory is injected
/// via `PATH`.
///
/// Returns `.Spawn_Failed` when the process cannot be started (or the
/// executable is not found in PATH), `.Wait_Failed` when waiting fails
/// or the child does not exit normally, and `.NonZero_Exit` (with the
/// exit status in `exit_code`) when it exits with a non-zero status.
run_process :: proc(
	command: string,
	args: []string,
	temp: runtime.Allocator = context.temp_allocator,
	stdin: ^os.File = os.stdin,
	stdout: ^os.File = os.stdout,
	stderr: ^os.File = os.stderr,
	child_env: []string = nil,
) -> Error {
	if len(command) == 0 {
		return Error{kind = .Invalid_Arg, msg = "command must not be empty"}
	}

	// Odin core's `os.process_start` looks up unqualified commands via the
	// *parent* process's PATH -- not via `desc.env`. Since this package's
	// whole point is to spawn `ssh`/`scp` (which may be supplied via a
	// stub PATH for testing, or via the user's PATH in production), do the
	// PATH lookup ourselves here. If the executable can't be located, fail
	// with `.Spawn_Failed` rather than letting `process_start` fall back to
	// the wrong binary and exit with status 255.
	resolved_command, found := resolve_command(command, child_env, temp, temp)
	if !found {
		return Error{kind = .Spawn_Failed, msg = command}
	}
	// Only the path we resolved ourselves needs freeing; when the caller
	// already passed an absolute path, `resolved_command` aliases `command`
	// and we must not free it.
	defer if resolved_command != command {
		delete(resolved_command, temp)
	}

	cmd := make([dynamic]string, temp)
	append(&cmd, resolved_command)
	for a in args {
		append(&cmd, a)
	}
	// `cmd` is copied into the kernel by process_start; release our
	// copy before returning so this procedure leaves nothing on `temp`.
	defer delete(cmd)

	p, e := os.process_start(
		os.Process_Desc{
			command = cmd[:],
			stdin   = stdin,
			stdout  = stdout,
			stderr  = stderr,
			env     = child_env,
		},
	)
	if e != nil {
		return Error{kind = .Spawn_Failed, msg = command, os_err = e}
	}

	state, werr := os.process_wait(p)
	if werr != nil {
		return Error{kind = .Wait_Failed, msg = command, os_err = werr}
	}
	if !state.exited {
		return Error{kind = .Wait_Failed, msg = command}
	}

	if state.exit_code != 0 {
		return Error{kind = .NonZero_Exit, msg = command, exit_code = state.exit_code}
	}

	return {}
}

/// execute_ssh connects to the VM: `ssh -F <config> -p <port> localhost [command]`.
///
/// An empty `command` opens an interactive shell; a non-empty
/// `command` is passed as a single argument to be run by the remote
/// shell. The child's standard streams are wired to the parent's
/// (see `run_process`).
///
/// Returns `.kind == .None` on success; see `run_process` for the
/// failure kinds.
execute_ssh :: proc(
	config_path: string,
	port: int,
	command: string,
	temp: runtime.Allocator = context.temp_allocator,
	stdin: ^os.File = os.stdin,
	stdout: ^os.File = os.stdout,
	stderr: ^os.File = os.stderr,
	child_env: []string = nil,
) -> Error {
	if len(config_path) == 0 {
		return Error{kind = .Invalid_Arg, msg = "config path must not be empty"}
	}
	if port < 1 || port > 65535 {
		return Error{kind = .Invalid_Arg, msg = "port out of range [1;65535]"}
	}

	args := make([dynamic]string, temp)
	// `args` is copied into the child command by run_process; release
	// ours before returning. The transient strings below are deferred
	// individually so they survive until run_process has consumed them
	// (defers run LIFO, so the strings outlive the backing array).
	defer delete(args)
	append(&args, "-F")
	append(&args, config_path)
	append(&args, "-p")
	port_str := fmt.aprintf("%d", port, allocator = temp)
	defer delete(port_str, temp)
	append(&args, port_str)
	append(&args, "localhost")
	if len(command) > 0 {
		append(&args, command)
	}

	return run_process("ssh", args[:], temp, stdin, stdout, stderr, child_env)
}

/// scp_put uploads a local path to the VM:
/// `scp -F <config> -P <port> [-r] <local> localhost:<remote>`.
///
/// `recursive` passes `-r`, which scp requires when transferring
/// directories. Like the Go original, `-r` is also enabled
/// automatically when `local` is a directory.
///
/// Returns `.kind == .None` on success; see `run_process` for the
/// failure kinds.
scp_put :: proc(
	config_path: string,
	port: int,
	local: string,
	remote: string,
	recursive: bool,
	temp: runtime.Allocator = context.temp_allocator,
	stdin: ^os.File = os.stdin,
	stdout: ^os.File = os.stdout,
	stderr: ^os.File = os.stderr,
	child_env: []string = nil,
) -> Error {
	if len(config_path) == 0 {
		return Error{kind = .Invalid_Arg, msg = "config path must not be empty"}
	}
	if port < 1 || port > 65535 {
		return Error{kind = .Invalid_Arg, msg = "port out of range [1;65535]"}
	}
	if len(local) == 0 {
		return Error{kind = .Invalid_Arg, msg = "local path must not be empty"}
	}
	if len(remote) == 0 {
		return Error{kind = .Invalid_Arg, msg = "remote path must not be empty"}
	}

	// Best effort, like the Go original: uploading a directory needs -r.
	recursive := recursive || os.is_directory(local)

	args := make([dynamic]string, temp)
	// `args` is copied into the child command by run_process; release
	// ours before returning. The transient strings below are deferred
	// individually so they survive until run_process has consumed them.
	defer delete(args)
	append(&args, "-F")
	append(&args, config_path)
	append(&args, "-P")
	port_str := fmt.aprintf("%d", port, allocator = temp)
	defer delete(port_str, temp)
	append(&args, port_str)
	if recursive {
		append(&args, "-r")
	}
	append(&args, local)
	remote_addr := fmt.aprintf("localhost:%s", remote, allocator = temp)
	defer delete(remote_addr, temp)
	append(&args, remote_addr)

	return run_process("scp", args[:], temp, stdin, stdout, stderr, child_env)
}

/// scp_get downloads a path from the VM:
/// `scp -F <config> -P <port> [-r] localhost:<remote> <local>`.
///
/// `recursive` passes `-r`, which scp requires when downloading a
/// directory. (Deviation from the Go original, which never passed
/// `-r` for downloads.)
///
/// Returns `.kind == .None` on success; see `run_process` for the
/// failure kinds.
scp_get :: proc(
	config_path: string,
	port: int,
	remote: string,
	local: string,
	recursive: bool,
	temp: runtime.Allocator = context.temp_allocator,
	stdin: ^os.File = os.stdin,
	stdout: ^os.File = os.stdout,
	stderr: ^os.File = os.stderr,
	child_env: []string = nil,
) -> Error {
	if len(config_path) == 0 {
		return Error{kind = .Invalid_Arg, msg = "config path must not be empty"}
	}
	if port < 1 || port > 65535 {
		return Error{kind = .Invalid_Arg, msg = "port out of range [1;65535]"}
	}
	if len(remote) == 0 {
		return Error{kind = .Invalid_Arg, msg = "remote path must not be empty"}
	}
	if len(local) == 0 {
		return Error{kind = .Invalid_Arg, msg = "local path must not be empty"}
	}

	args := make([dynamic]string, temp)
	// `args` is copied into the child command by run_process; release
	// ours before returning. The transient strings below are deferred
	// individually so they survive until run_process has consumed them.
	defer delete(args)
	append(&args, "-F")
	append(&args, config_path)
	append(&args, "-P")
	port_str := fmt.aprintf("%d", port, allocator = temp)
	defer delete(port_str, temp)
	append(&args, port_str)
	if recursive {
		append(&args, "-r")
	}
	remote_addr := fmt.aprintf("localhost:%s", remote, allocator = temp)
	defer delete(remote_addr, temp)
	append(&args, remote_addr)
	append(&args, local)

	return run_process("scp", args[:], temp, stdin, stdout, stderr, child_env)
}

// resolve_command is a thin wrapper around `subprocess.Find_Executable`,
// kept for the SSH package's existing call sites. Behaviour is identical:
// path-literal candidates require execute-bit, PATH lookup honours
// `env`'s `PATH=` entry then falls back to the parent's PATH.
@(private="package")
resolve_command :: proc(command: string, env: []string, out_alloc, temp: runtime.Allocator) -> (resolved: string, found: bool) {
	return sp.Find_Executable(command, env, out_alloc, temp)
}
