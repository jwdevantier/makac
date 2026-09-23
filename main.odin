// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package makac

import "core:fmt"
import "core:os"
import "core:strings"
import ap "./argparse"
import dd "./datadir"
import "./vm"

USAGE ::
`usage: makac [--version] <command> [args]

commands:
  init <path>     initialize a .makac data directory
  run <workflow>  run a workflow file
  fetch           fetch packages listed in .makac/packages.lua

flags:
  --version       print version (major.minor) and exit
`

version_flag := ap.Flag {
	long  = "version",
	desc  = "print version (major.minor) and exit",
	value = .None,
}

init_cmd := ap.Command {
	name = "init",
	help = "initialize a .makac data directory",
}

run_cmd := ap.Command {
	name = "run",
	help = "run a workflow file",
}

fetch_cmd := ap.Command {
	name = "fetch",
	help = "fetch packages listed in .makac/packages.lua",
}

root_cmd := ap.Command {
	name     = "makac",
	flags    = {version_flag},
	commands = {&init_cmd, &run_cmd, &fetch_cmd},
}

main :: proc() {
	args := os.args[1:]
	res, ok := ap.parse_args(&root_cmd, args)
	if !ok {
		fmt.eprintf("makac: failed to parse arguments\n")
		fmt.eprint(USAGE)
		os.exit(1)
	}

	pc, found := ap.last_command(res)
	if !found {
		fmt.eprint(USAGE)
		os.exit(1)
	}

	// `makac --version` — the flag lives on the root command and short-
	// circuits everything else (no datadir resolution, no VM). Prints the
	// same major.minor pair makac.env.version() reports (single source of
	// truth: vm.VERSION_*).
	if pc.source.name == "makac" {
		if _, has := pc.flags["version"]; has {
			fmt.printf("%d.%d\n", vm.VERSION_MAJOR, vm.VERSION_MINOR)
			os.exit(0)
		}
	}

	switch pc.source.name {
	case "init":
		pargs, _ := ap.find_args(res)
		if len(pargs.value) != 1 {
			fmt.eprintf("makac: init takes exactly one <path> argument\n")
			fmt.eprint(USAGE)
			os.exit(1)
		}
		if err := dd.init(pargs.value[0]); err != .None {
			fmt.eprintf("makac: init: failed to create data directory at '%s'\n", pargs.value[0])
			os.exit(1)
		}
		fmt.printf("makac: initialized data directory at %s\n", pargs.value[0])
	case "run":
		dir, rok := resolve_datadir()
		if !rok {os.exit(1)}
		defer delete(dir)
		pargs, _ := ap.find_args(res)
		if len(pargs.value) != 1 {
			fmt.eprintf("makac: run takes exactly one <workflow> argument\n")
			fmt.eprint(USAGE)
			os.exit(1)
		}
		v := vm.new(dir)
		if v == nil {
			fmt.eprintf("makac: failed to create Lua VM\n")
			os.exit(1)
		}
		defer vm.close(v)
		// Load fetched packages BEFORE evaluating the workflow (task23):
		// their actions/fetchers join makac's registries as '<id>:<name>'
		// and their lib/ is require-able via 'pkgs/<id>/...' (task22).
		// Nothing fetched (.makac/packages absent or empty) is skipped
		// silently — fetching is the user's explicit 'makac fetch' step,
		// never automatic.
		ok := true
		err: vm.Error
		if lerr, lok := vm.run_string(v, "makac.load_packages()"); !lok {
			err, ok = lerr, false
		} else {
			if lerr.message != "" {delete(lerr.message)}
			err, ok = vm.run_file(v, pargs.value[0])
		}
		// design/target.md: "the runner closes every target when the
		// workflow finishes" — unconditionally, even when the workflow (or
		// package loading above — package-provided actions can create
		// targets too) failed, leaving SSH control masters etc. behind
		// otherwise.
		_, terr := vm.call_named(v, "makac.close_all_targets")
		if terr.message != "" {
			fmt.eprintf("makac: warning: closing targets failed: %s\n", terr.message)
			delete(terr.message)
		}
		if !ok {
			report_error(err.message)
			if err.message != "" {delete(err.message)}
			os.exit(1)
		}
		if err.message != "" {delete(err.message)}
	case "fetch":
		dir, rok := resolve_datadir()
		if !rok {os.exit(1)}
		defer delete(dir)
		pkgs_path := strings.concatenate([]string{dir, "/packages.lua"}, context.temp_allocator)
		if !os.exists(pkgs_path) {
			// nothing to fetch is NOT an error; explain where the file goes
			// and what it must look like (explore-through-help-output)
			fmt.printf(`makac: no packages.lua found.

The package list for this project lives at:
  %s
Create it (a Lua file that MUST return a table of package entries), e.g.:

  -- .makac/packages.lua
  return {{
    {{
      id = "qemu",              -- referenced as 'qemu:<action>' in workflows
      fetcher = "fetchgit",     -- built-in fetchers: "fetchurl", "fetchgit", "filesystem"
      with = {{                  -- arguments for the fetcher
        url = "https://github.com/user/some-repo.git",
        rev = "main",
      }},
    }},
  }}

Then run 'makac fetch' again.
`, pkgs_path)
			os.exit(0)
		}
		v := vm.new(dir)
		if v == nil {
			fmt.eprintf("makac: failed to create Lua VM\n")
			os.exit(1)
		}
		defer vm.close(v)
		// the fetch driver lives in the prelude (fetchers are Lua functions):
		// it validates the entries, resolves each fetcher and fetches every
		// package in order, aborting with a non-zero exit on the first failure
		ferr, fok := vm.run_string(v, "makac.fetch_all()")
		if !fok {
			report_error(ferr.message)
			if ferr.message != "" {delete(ferr.message)}
			os.exit(1)
		}
		if ferr.message != "" {delete(ferr.message)}
	case:
		fmt.eprint(USAGE)
		os.exit(1)
	}
}

// Print an error to stderr; Lua-side errors already carry the "makac: "
// prefix, don't repeat it.
report_error :: proc(msg: string) {
	if strings.has_prefix(msg, "makac:") {
		fmt.eprintf("%s\n", msg)
	} else {
		fmt.eprintf("makac: %s\n", msg)
	}
}

// Resolve the data directory from the CWD, printing the resolution error and
// advice (and returning ok=false) when the project root cannot be determined.
resolve_datadir :: proc() -> (dir: string, ok: bool) {
	cwd, e := os.get_working_directory(context.temp_allocator)
	if e != nil {
		fmt.eprintf("makac: cannot determine working directory: %s\n", os.error_string(e))
		return "", false
	}
	d, derr := dd.resolve(cwd)
	switch derr {
	case .None:
		return d, true
	case .Mkdir_Failure:
		fmt.eprintf("makac: found project root but failed to create '.makac'\n")
	case .Not_Found:
		fmt.eprintf(
			"makac: could not determine the root of the project (no '.makac' or '.git' found)\n",
		)
		fmt.eprintf("makac: initialize the data directory with: makac init <path>\n")
	}
	return "", false
}
