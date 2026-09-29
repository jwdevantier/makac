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
	// The data directory exists, but its sibling project file
	// (`makac_project.lua`) could not be created.
	Project_File_Failure,
}

// PROJECT_FILE_NAME is the project's dependency file: a file that lives
// BESIDE the data directory, in the project root, not inside it
// (design/packages.md).
PROJECT_FILE_NAME :: "makac_project.lua"

// PROJECT_FILE_TEMPLATE is what a freshly created project file contains. It is
// valid Lua (empty `inputs` and `packages` tables) plus enough documentation
// to get started.
PROJECT_FILE_TEMPLATE ::
`-- makac_project.lua — this project's dependency wiring.
--
-- 'inputs' says where each package comes from. The key is a local LABEL for
-- the fetch instruction:
--
--   return {
--     inputs = {
--       qemu = { fetcher = "fetchgit",
--         with = { url = "https://github.com/user/repo.git", rev = "main" } },
--     },
--     packages = { qemu = "qemu" },
--   }
--
-- 'packages' wires an alias to an input label. Aliases are the names workflows
-- and packages use: 'qemu:<action>' in a step's uses field,
-- require("pkgs/qemu/...") in Lua.
--
-- Fetchers in this file: the built-ins ("fetchurl", "fetchgit", "filesystem")
-- or any fetcher provided by another package of this project ('makac fetch'
-- keeps retrying inputs until it cannot make progress). Fetched code is
-- stored content-addressed under .makac/packages/<key>/; stale entries are
-- pruned after each fetch. Packages are fetched explicitly: run 'makac fetch'
-- after editing.
return { inputs = {}, packages = {} }
`

// project_file_path returns the project file belonging to a data directory:
// its sibling `<project root>/makac_project.lua`.
project_file_path :: proc(data_dir: string, allocator := context.allocator) -> string {
	root := filepath.dir(data_dir)
	return filepath.join({root, PROJECT_FILE_NAME}, allocator) or_else ""
}

// ensure_project_file writes PROJECT_FILE_TEMPLATE next to `data_dir` unless a
// project file already exists. It is called wherever makac creates a data
// directory, so a new project is immediately ready for `makac fetch`
// (design/cli.md).
ensure_project_file :: proc(data_dir: string) -> Error {
	path := project_file_path(data_dir, context.temp_allocator)
	if path == "" {return .Project_File_Failure}
	if os.exists(path) {return .None}
	if err := os.write_entire_file_from_string(path, PROJECT_FILE_TEMPLATE); err != nil {
		return .Project_File_Failure
	}
	return .None
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
			if plerr := ensure_project_file(makac); plerr != .None {
				return "", plerr
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
// Creating an already-existing directory is not an error. In both cases the
// sibling project file `makac_project.lua` is created (if absent), since
// creating the data directory is what makes a location a makac project.
init :: proc(path: string) -> Error {
	target := path
	if !strings.has_suffix(path, ".makac") {
		target = filepath.join({path, ".makac"}, context.temp_allocator) or_else ""
	}
	if !os.is_dir(target) {
		if err := os.make_directory_all(target); err != nil {
			return .Mkdir_Failure
		}
	}
	return ensure_project_file(target)
}
