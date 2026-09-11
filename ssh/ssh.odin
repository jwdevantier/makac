// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause

/*
ssh - SSH config generation and ssh/scp execution helpers for oqqmgr VMs.

This package mirrors the SSH functionality of the original Go qqmgr tool.
It never speaks the SSH protocol itself:

  * `generate_config` writes an OpenSSH config file for a VM
    (`<data_dir>/ssh.conf`) from a global `[ssh]` option table and a
    per-VM option table, and creates the data directory plus the sibling
    `<data_dir>/ssh/` control-socket directory. The options typically
    enable connection multiplexing (ControlMaster / ControlPath /
    ControlPersist), so that every later invocation -- including the
    scp transfers below -- reuses the already-authenticated master
    connection instead of re-authenticating.

  * `execute_ssh`, `scp_put`, `scp_get` shell out to the system
    `ssh` / `scp` binaries, passing the generated config via `-F`.
    The child's stdin/stdout/stderr are wired to the parent's by
    default, so interactive sessions and password prompts work.

Deviations from the Go original (documented):
  * Option tables are written in *sorted* key order within each table,
    instead of Go's random map iteration order.
  * The returned config path is *absolute*, even when `data_dir` is
    relative, so neither the `-F` argument nor the control-socket path
    depend on the directory `ssh` happens to run in.
  * `scp_put` and `scp_get` take an explicit `recursive` flag. `scp_get`
    may pass `-r` (the original never did for downloads); `scp_put`
    additionally enables `-r` automatically when the local path is a
    directory, like the original's stat check.

Memory model
------------
  * Input tables, strings and paths are caller-owned; this package
    never frees them.
  * The config `path` returned by `generate_config` is caller-owned
    (allocated from `perm`, made absolute); free it with
    `delete(path, perm)`.
  * Errors are plain values: nothing inside an `Error` is allocated
    by this package, so there is nothing to free. `error_string`
    renders an `Error` for display from the temp allocator.
  * Interim allocations are made from `temp` and released before
    returning.
  * Failures are reported through values (`Error`), not panics.
*/
package ssh

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"

/// An SSH config option value.
///
/// Each variant is formatted the way Go's `%v` verb would format it:
/// `string` as-is, `i64` as a decimal integer, `f64` as a float
/// (300 => "300", 3.5 => "3.5"), `bool` as "true"/"false".
/// Initialize with a plain value of the variant type (unions have no
/// compound literal syntax), e.g. `i64(3)`, `"auto"`.
Option_Value :: union {
	string,
	i64,
	f64,
	bool,
}

/// A table of SSH options; the equivalent of the Go original's
/// `map[string]interface{}` for the global `[ssh]` table and the
/// per-VM `[vm.<name>.ssh]` tables.
Option_Table :: map[string]Option_Value

/// The kind of a failure reported by this package. `.None` means success.
Error_Kind :: enum {
	None,
	Invalid_Arg,  // bad argument (empty path, out-of-range port)
	Mkdir_Failed, // failed to create the data / control-socket directory
	Write_Failed, // failed to create or write the config file
	Spawn_Failed, // failed to start the ssh/scp child (e.g. not in PATH)
	Wait_Failed,  // failed to wait for the child, or it did not exit normally
	NonZero_Exit, // the child exited with a non-zero status
}

/// A failure, reported through a value.
///
/// `kind == .None` means success (a zero `Error{}` is a valid "no error").
/// `msg` is optional context (a string literal or a caller-owned string
/// such as the command name); this package never allocates or frees it.
/// `os_err` is the underlying OS error when there is one.
/// For `.NonZero_Exit`, `exit_code` holds the child's exit status.
Error :: struct {
	kind:      Error_Kind,
	msg:       string,
	os_err:    os.Error,
	exit_code: int,
}

/// Human-readable description of `err`, e.g. for logging.
/// The result is allocated from the temp allocator.
error_string :: proc(err: Error) -> string {
	if err.kind == .None {
		return "no error"
	}

	base := error_kind_string(err.kind)
	if len(err.msg) > 0 {
		base = fmt.tprintf("%s (%s)", base, err.msg)
	}
	if err.kind == .NonZero_Exit {
		return fmt.tprintf("%s, exit status %d", base, err.exit_code)
	}
	if err.os_err != nil {
		return fmt.tprintf("%s: %s", base, os.error_string(err.os_err))
	}
	return base
}

@(private="package")
error_kind_string :: proc(kind: Error_Kind) -> string {
	switch kind {
	case .None:         return "no error"
	case .Invalid_Arg:  return "invalid argument"
	case .Mkdir_Failed: return "failed to create directory"
	case .Write_Failed: return "failed to write config file"
	case .Spawn_Failed: return "failed to spawn ssh/scp"
	case .Wait_Failed:  return "failed to wait for ssh/scp"
	case .NonZero_Exit: return "ssh/scp exited with non-zero status"
	}
	return "unknown error"
}

/// True when `key` begins with a lowercase ASCII letter. Such keys are
/// qqmgr pseudo-options (`port`, `vm_port`), not real SSH options; they
/// are never written to the config file.
is_pseudo_option :: proc(key: string) -> bool {
	return len(key) > 0 && key[0] >= 'a' && key[0] <= 'z'
}

/// generate_config writes an OpenSSH config file for a VM.
///
/// The file is written to `<data_dir>/ssh.conf`. `data_dir` is created
/// recursively if needed, along with the sibling control-socket
/// directory `<data_dir>/ssh/`, where the ControlMaster sockets live.
///
/// The file content is the `global` options first, then the `vm`
/// options, each table sorted by key (deterministic; the Go original
/// iterated its maps in random order). Two rewrites keep the file
/// faithful:
///   * keys starting with a lowercase letter in the `vm` table -- the
///     qqmgr pseudo-options `port` and `vm_port` -- are never written,
///   * a *relative* string `ControlPath` in the `global` table is
///     rewritten to an absolute path inside the control-socket
///     directory (using its last element), so the socket location does
///     not depend on the directory `ssh` is started from.
///
/// On success returns the absolute path of the written file (even when
/// `data_dir` is relative), to be passed to `execute_ssh` / `scp_put` /
/// `scp_get` as the config path. The returned `path` is allocated from
/// `perm` and is *caller-owned* (free with `delete(path, perm)`).
///
/// On failure returns a non-`.None` `err`.
generate_config :: proc(
	data_dir: string,
	global: Option_Table,
	vm: Option_Table,
	perm: runtime.Allocator = context.allocator,
	temp: runtime.Allocator = context.temp_allocator,
) -> (path: string, err: Error) {
	if len(data_dir) == 0 {
		return "", Error{kind = .Invalid_Arg, msg = "data_dir must not be empty"}
	}

	// <data_dir>/ssh.conf, kept absolute so neither the `-F` argument nor
	// the ControlPath rewrite below depend on the process cwd.
	rel, ae := os.join_path({data_dir, "ssh.conf"}, temp)
	if ae != nil {
		return "", Error{kind = .Invalid_Arg, msg = "invalid data_dir", os_err = ae}
	}
	defer delete(rel, temp)

	abs, werr := absolute_path(rel, perm)
	if werr != nil {
		return "", Error{kind = .Write_Failed, msg = "resolve absolute config path", os_err = werr}
	}
	// `abs` is allocated from `perm`. On the happy path it is returned
	// (caller-owned). On every error path below it must be released --
	// otherwise a failed config generation silently leaks the path string.
	defer if err.kind != .None {
		delete(abs, perm)
	}

	data_dir_abs := os.dir(abs)
	control_dir, ce := os.join_path({data_dir_abs, "ssh"}, temp)
	if ce != nil {
		return "", Error{kind = .Write_Failed, os_err = ce}
	}
	defer delete(control_dir, temp)

	// The data directory, then the control-socket directory next to it.
	if merr := ensure_directory(data_dir_abs); merr != nil {
		return "", Error{kind = .Mkdir_Failed, os_err = merr}
	}
	if merr := ensure_directory(control_dir); merr != nil {
		return "", Error{kind = .Mkdir_Failed, os_err = merr}
	}

	content := build_content(global, vm, control_dir, temp)
	// The builder's buffer is allocated from `temp`; the file write below
	// copies from it, so destroy the builder once written on every path.
	defer strings.builder_destroy(&content)

	if werr := os.write_entire_file_from_string(abs, strings.to_string(content)); werr != nil {
		return "", Error{kind = .Write_Failed, os_err = werr}
	}

	return abs, {}
}

/// Build the full file content: the `global` options first, then the
/// `vm` options (see `generate_config` for the rewrites).
@(private="package")
build_content :: proc(
	global, vm: Option_Table,
	control_dir: string,
	a: runtime.Allocator,
) -> (sb: strings.Builder) {
	sb, _ = strings.builder_make(a)
	append_table(&sb, global, control_dir, false, true, a)
	append_table(&sb, vm, control_dir, true, false, a)
	return
}

/// Append the options of one table to `sb`, one `Key value` line per
/// option, sorted by key.
///
/// `skip_lowercase` drops keys starting with a lowercase letter (the
/// qqmgr pseudo-options `port` / `vm_port`, which are not real SSH
/// options); `rewrite_control_path` absolutizes a relative string
/// `ControlPath` value inside `control_dir`.
@(private="package")
append_table :: proc(
	sb: ^strings.Builder,
	table: Option_Table,
	control_dir: string,
	skip_lowercase: bool,
	rewrite_control_path: bool,
	a: runtime.Allocator,
) {
	keys := make([dynamic]string, a)
	for k in table {
		append(&keys, k)
	}
	sort.quick_sort(keys[:])
	// `keys` is allocated from `a`; release it once sorted/iterated.
	defer delete(keys)

	for k in keys {
		if len(k) == 0 {
			continue
		}
		if skip_lowercase && is_pseudo_option(k) {
			continue
		}

		value := table[k]
		#partial switch x in value {
		case string:
			if rewrite_control_path && k == "ControlPath" && !os.is_absolute_path(x) {
				// Anchor a relative ControlPath in the control
				// directory, using only its last path element, so
				// the socket location does not depend on the cwd
				// ssh is started from.
				if joined, je := os.join_path({control_dir, os.base(x)}, a); je == nil {
					fmt.sbprintf(sb, "%s %s\n", k, joined)
					delete(joined, a)
					continue
				}
			}
			fmt.sbprintf(sb, "%s %s\n", k, x)
		case i64:
			fmt.sbprintf(sb, "%s %d\n", k, x)
		case f64:
			// Go's %v uses %g for float64.
			fmt.sbprintf(sb, "%s %g\n", k, x)
		case bool:
			fmt.sbprintf(sb, "%s %s\n", k, (x ? "true" : "false"))
		case:
			// A nil option value is written with no line.
		}
	}
}

/// `os.make_directory_all(path, 0755)`, treating "already exists as a
/// directory" as success: `make_directory_all` returns `.Exist` when the
/// path already exists, so that case is downgraded here; only real
/// failures (e.g. a regular file in the path's place) are errors.
@(private="package")
ensure_directory :: proc(path: string) -> os.Error {
	err := os.make_directory_all(path, os.perm_number(0o755))
	if err == .Exist && os.is_directory(path) {
		return nil
	}
	return err
}

/// `filepath.Abs` equivalent: prefix the working directory when needed
/// and clean the result. Unlike `os.get_absolute_path` this never
/// touches the filesystem, so it also works for paths that do not
/// exist (yet).
@(private="package")
absolute_path :: proc(path: string, allocator: runtime.Allocator) -> (abs: string, err: os.Error) {
	if os.is_absolute_path(path) {
		return os.clean_path(path, allocator)
	}

	wd, werr := os.get_working_directory(allocator)
	if werr != nil {
		return "", werr
	}
	defer delete(wd, allocator)

	joined, jaerr := os.join_path({wd, path}, allocator)
	if jaerr != nil {
		return "", jaerr
	}
	defer delete(joined, allocator)

	return os.clean_path(joined, allocator)
}
