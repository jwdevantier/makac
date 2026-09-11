// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

import "core:fmt"

// Prelude is the embedded Lua stdlib (registries, `step`, built-in actions,
// fact finders, target wrappers, the `pkgs:` module searcher). It lives in
// prelude.lua at the repository root and is baked into the binary with the
// `#load` directive so a built makac is fully self-contained.
Prelude :: #load("../prelude.lua", string)

// Evaluate the embedded prelude in `v`. Must run after the standard library
// is opened and after all Odin-side builtins are registered (`new` takes care
// of the ordering), and before any user-facing Lua is evaluated, so that
// every workflow sees prelude definitions.
init_prelude :: proc(v: ^VM) -> (err: Error, ok: bool) {
	return run_string(v, Prelude, "@prelude.lua")
}

// Evaluate the prelude or die trying. The prelude is baked into the binary
// and under our control, so a failure here is a makac bug, never user error;
// there is nothing meaningful a caller could do to recover.
must_init_prelude :: proc(v: ^VM) {
	if err, ok := init_prelude(v); !ok {
		fmt.eprintfln("makac: internal error evaluating embedded prelude: %s", err.message)
		delete(err.message)
		panic("embedded prelude failed to evaluate")
	}
}
