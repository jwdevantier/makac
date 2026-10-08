# API conformance suite

Runs **inside** the VM of the binary under test and pins the expanded makac
API — every `makac.*` primitive, the `path`/`Dir` userdata, the prelude DSL
(registries, `step`, targets, defer) and the package machinery — with in-VM
assertions on return shapes, error semantics and edge cases. One process,
~60 pinned contracts.

```bash
# against the reference (Odin) binary — one known-crashing case quarantined
# (see docs/findings.md #1):
MAKAC_API_SKIP=fs/write_read_roundtrip_with_nul_bytes makac run tests/api/run.lua

# against the Zig port (should need NO quarantine):
./zig-out/bin/makac run tests/api/run.lua
```

## Layout

- `run.lua` — entry workflow; loads spec modules, runs, reports
  (`ok`/`not ok`/`skip`, exit 1 on failure).
- `lib/api.lua` — tiny framework: groups/cases, assertions incl.
  `raises(fn, substring)`, fixture dirs under one tmp root, and the
  quarantine list (`MAKAC_API_SKIP=<group>/<case>[,...]`).
- `specs/*.lua` — one file per area; each case cites its doc contract and
  marks probed (rather than documented) behavior inline.

## Relationship to the other tiers

- `tests/blackbox/` — CLI-observable behavior across process spawns
  (reporting, exit codes, stdout/stderr split). What *users* see.
- `tests/api/` (here) — the in-VM contract: what *workflow and package code*
  sees. The `surface` spec (presence of every documented name with its type)
  is the cheapest regression net while the Zig port lands primitives
  incrementally.
- Docs-level truth lives in `~/repos/makac/site` + `~/repos/makac/design`;
  divergences from the reference implementation are recorded in
  `docs/findings.md` — assert the *documented* behavior, record the rest.

## Gotchas for spec authors

- Registry mutations persist for the whole run: use `apitest`-prefixed
  action/fetcher names, and remember `close_all_targets()` closes even
  `makac.host` (order those cases last in the targets group).
- `step` reports to stderr with colors when the outer run allows it —
  cosmetic; pass `NO_COLOR=1` for clean logs.
- `path` values compare by identity (no `__eq`) — `tostring()` before `eq`.
