// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package datadir

import "core:os"
import "core:path/filepath"
import "core:strings"

Error :: enum {
	None,
	// Neither a `.makac` nor a `.git` directory was found in any ancestor; the
	// project root could not be determined.
	Not_Found,
	// A candidate location was found but the `.makac` directory could not be
	// created.
	Mkdir_Failure,
}

// Resolve the project's data directory per design/data_directory.md:
// walking up from `start_dir`, return the first `.makac` directory found;
// otherwise, at the first directory containing `.git`, create `.makac` there
// and return it. If the filesystem root is reached with neither found,
// return .Not_Found.
resolve :: proc(
	start_dir: string,
	allocator := context.allocator,
) -> (dir_path: string, err: Error) {
	dir := filepath.abs(start_dir, context.temp_allocator) or_else start_dir

	// The walk terminates on its own at the filesystem root (`parent == dir`);
	// limit iterations to avoid infinite loops on a cycle.
	MAX_WALK_UP :: 64
	for max_iter := MAX_WALK_UP; max_iter > 0; max_iter -= 1 {
		makac := filepath.join({dir, ".makac"}, context.temp_allocator) or_else ""
		if os.is_dir(makac) {
			return strings.clone(makac, allocator), .None
		}
		git := filepath.join({dir, ".git"}, context.temp_allocator) or_else ""
		if os.is_dir(git) {
			if mkerr := os.make_directory_all(makac); mkerr != nil {
				return "", .Mkdir_Failure
			}
			return strings.clone(makac, allocator), .None
		}
		parent := filepath.dir(dir)
		if parent == dir {
			return "", .Not_Found
		}
		dir = parent
	}

	return "", .Not_Found
}

// Initialize a data directory per design/cli.md: if `path` ends with
// `.makac`, create exactly that directory; otherwise create `<path>/.makac`.
// Creating an already-existing directory is not an error.
init :: proc(path: string) -> Error {
	target := path
	if !strings.has_suffix(path, ".makac") {
		target = filepath.join({path, ".makac"}, context.temp_allocator) or_else ""
	}
	if os.is_dir(target) {
		return .None
	}
	if err := os.make_directory_all(target); err != nil {
		return .Mkdir_Failure
	}
	return .None
}
