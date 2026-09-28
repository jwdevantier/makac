// SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
// SPDX-License-Identifier: BSD-2-Clause
package vm

// makac's version, as reported by `makac.env.version()` and, in turn, the
// root command's `--version` flag (main.odin).
//
// These define the static fallbacks baked into ordinary builds. The release
// workflow rewrites them (scripts/bump-version.sh) before tagging, and
// `-define:MAKAC_VERSION_MAJOR=..` / `-define:MAKAC_VERSION_MINOR=..` override
// them at compile time (Odin's `#config`, see `odin help build`). Either way
// the pair is compiled in; nothing is read at run time.
//
// Scheme: MAJOR increments on incompatible changes to EXISTING APIs, MINOR
// on added APIs; while major is 0, minor bumps may include incompatible
// changes — the discipline starts at 1.0.
VERSION_MAJOR :: #config(MAKAC_VERSION_MAJOR, 0)
VERSION_MINOR :: #config(MAKAC_VERSION_MINOR, 4)
