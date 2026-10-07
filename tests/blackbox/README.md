# Black-box test suite

A makac-workflow-driven test suite that exercises a makac binary purely
through its CLI: init/run/fetch/doctor, step reporting, the shell/facts
actions, package fetching, and so on. It is the **porting contract** for the
Zig reimplementation: behavior here is derived from `~/repos/makac/site/` and
`~/repos/makac/design/` (the docs), not from reading the Odin source.

The harness *is itself a makac workflow* (dogfooding):

```bash
# 1. develop the harness against the reference (Odin) binary
makac tests/blackbox/run.lua

# 2. zig binary under test, harness driven by the reference binary
makac tests/blackbox/run.lua ./zig-out/bin/makac

# 3. full self-host: the zig binary runs the harness against itself —
#    proves Lua VM + exec/fs/etc. end to end before any assertion runs
./zig-out/bin/makac tests/blackbox/run.lua ./zig-out/bin/makac
```

The binary under test may also be given via `MAKAC_BIN`.

- **SSH suites**: `ssh` (always-on; PATH-injected fake ssh/scp pin the
  assembly layer) runs everywhere. `ssh_real` starts a self-contained
  localhost `sshd` — auto-detected (needs `sshd` + `ssh-keygen` on PATH,
  provided by the flake's `testing` shell), opt out with `MAKAC_TEST_SSH=0`.
- **QMP / download suites**: need python3 (a scripted fake QMP server in
  `servers/`, resp. a loopback `http.server`); auto-skip when absent.
- **Quarantine**: `MAKAC_BB_SKIP=<suite>/<case>[,...]` skips cases pinning
  documented behavior where an implementation is known to diverge (see
  docs/findings.md); against the Odin reference today:
  `MAKAC_BB_SKIP=qmp/json_numbers_decode_integers`.

## Layout

- `run.lua` — entry workflow; resolves the binary, loads suites, reports
  (`ok` / `not ok` lines on stdout, exit 1 on any failure).
- `lib/harness.lua` — tiny framework: suites/cases, assertions, per-case
  throwaway tmp dir, `ctx.run(...)` invoking the binary with
  `MAKAC_COLOR=never` (deterministic stderr), output normalization
  (`h.norm`: tmp paths -> `<TMP>`, step timings -> `(Ts)`).
- `cases/<suite>.lua` — one file per suite. Each case names the doc contract
  it pins down.

## Rules of the game

- **Hermetic**: no network, no reliance on the invoking project (no packages,
  no data dir — cases needing a project build one in their tmp dir). Cases
  that cannot be hermetic (SSH, downloads over real HTTP) belong in a
  separate integration tier.
- The harness sticks to a **minimal API footprint** (`makac.exec`,
  `makac.fs.*`, `print`) so the young Zig binary can drive it.
- Assert **documented behavior**, including exact message shapes where the
  docs specify them ("step 'x' (uses 'shell') failed: ...", exit codes,
  stderr-vs-stdout split). Where the implementation contradicts the docs,
  that is a finding — record it, don't encode it.
