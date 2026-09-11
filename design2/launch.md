# Launch (and stop): the process choreography

This doc pins down *the code shape* of starting and stopping a VM, as
annotated pseudo-Lua, so implementation doesn't re-derive it. It stands on
three legs, all specified elsewhere:

* `makac.spawn(argv, { stdout =, stderr = })` -> process object with `p.pid`
  and `p:status()` (`stdlib.md`, "Processes") — the qqmgr `cmd/start.go`
  fork model: files for stdio, never pipes; the object never kills on GC and
  never owns the child's lifetime.
* the poll-loop primitives: `makac.time.sleep`/`makac.time.now` (monotonic),
  `makac.fs.stat`, `makac.pid_alive` (`stdlib.md`).
* the QMP client object (`feasibility.md`, "The QMP binding").

Semantics are **not** defined here — `vm.md` ("Start semantics", "Stop
semantics") and `handle.md` ("Probe") own them. What follows is the
reference shape of the code that implements them, with pointers to the rule
each line obeys.

## Start (`qemu:vm` with `state = "started"`, vm.md steps 1–5)

```lua
local time = makac.time   -- module alias; sleep/now below read better short

local function start(h, qemu_bin, args, ssh, wait_ssh)
  -- vm.md step 1: runtime dir; truncate previous run's logs
  makac.fs.mkdir_p(h.run_dir)
  makac.fs.write_file(h.qemu_stdout, "")
  makac.fs.write_file(h.qemu_stderr, "")

  -- vm.md step 2: probe + invocation identity (handle.md) — omitted here
  -- (same invocation -> no-op; different -> spec failure)

  -- write the canonical invocation for identity checks by later runs
  -- (vm.md, "Invocation identity": verbatim text, so failures can diff)
  makac.fs.write_file(h.run_dir .. "/invocation", canonical_invocation,
                      { atomic = true })

  -- vm.md step 3: launch detached — spawn, DO NOT wait. stdio to files.
  local p = makac.spawn({ qemu_bin, table.unpack(args) }, {
    stdout = h.qemu_stdout,
    stderr = h.qemu_stderr,
  })

  -- vm.md steps 3+4: the launch window. qqmgr slept a fixed 5s then checked;
  -- we poll — same detections, latency only when warranted.
  local qmp
  local deadline = time.now() + 5 * time.ns_per_s  -- short window, vm.md step 4
  while time.now() < deadline do
    -- early exit = launch failure (bad args, missing image): quote the log
    local st = p:status()
    if st ~= "running" then
      error(("qemu exited during launch (%s):\n%s"):format(
        st.code or "signal", tail(h.qemu_stderr, 40)))
    end
    if makac.fs.stat(h.qmp_socket) then
      -- retry briefly: the socket exists before QEMU accepts on it
      local ok, client = pcall(makac.qmp_open, h.qmp_socket)
      if ok then qmp = client break end
    end
    time.sleep(50 * time.ns_per_ms)
  end
  if qmp == nil then
    error(("qemu did not open %s within the launch window"):format(h.qmp_socket))
  end
  attach_qmp(h, qmp)                 -- handle.md: one client per handle

  -- vm.md step 5: wait for ssh (when configured and not wait_ssh = false)
  if ssh and wait_ssh ~= false then
    local t = target_for(h, ssh)     -- makac.new_ssh_target(name, {...})
    local timeout  = (wait_ssh and wait_ssh.timeout_s)  or 120
    local interval = (wait_ssh and wait_ssh.interval_s) or 2
    local deadline = time.now() + timeout * time.ns_per_s
    while true do
      local ok = pcall(function() return t:run({ "true" }) end)
      if ok then break end
      if time.now() >= deadline then
        error(("ssh to '%s' not up within %ds — see %s"):format(
          h.name, timeout, h.serial_log))
      end
      time.sleep(interval * time.ns_per_s)
    end
  end
end
```

Notes for the implementer:

* `tail(path, n)` (last *n* lines of the log for the failure message) is a
  shell-out to `tail(1)` via `makac.exec`, not a new primitive.
* The early-exit check must come *before* the socket check in each
  iteration: a racing exit + a leftover socket file from a previous run must
  not spell success.
* After the window, stop calling `p:status()` obsessively — the object has
  done its job. (If the VM dies mid-workflow it is a zombie until `makac`
  exits and init reaps it; cosmetic, and worth a code comment so nobody
  "fixes" it by adding a reaper.)
* `p.pid` answers "the pidfile": write `<run_dir>/pid` from it
  (atomically), the way QEMU's own `-pidfile` would. Probe (handle.md) reads
  the pidfile + `pid_alive`, never the process object — the object does not
  survive the run.

## Stop (`qemu:vm` with `state = "stopped"`, vm.md)

Same loop shape, two escalation levels:

```lua
local time = makac.time

local function stop(h, timeout_s, force)
  local st = probe(h)                  -- handle.md
  if not st.alive then cleanup_runtime_files(h) return { changed = false } end

  local qmp = qmp_of(h)                -- attach on demand if missing
  -- graceful: ACPI powerdown, then watch the process disappear
  qmp:send({ { execute = "system_powerdown" } })
  local deadline = time.now() + (timeout_s or 20) * time.ns_per_s
  while makac.pid_alive(st.pid) and time.now() < deadline do
    time.sleep(time.ns_per_s)
  end

  if makac.pid_alive(st.pid) and (force ~= false) then
    qmp:send({ { execute = "quit" } }) -- then, if STILL alive:
    time.sleep(200 * time.ns_per_ms)
    if makac.pid_alive(st.pid) then
      makac.exec({ "kill", "-9", tostring(st.pid) })
    end
  end
  if makac.pid_alive(st.pid) then
    error(("VM '%s' (pid %d) did not stop"):format(h.name, st.pid))
  end

  qmp:close()                          -- handle's connection goes with it
  cleanup_runtime_files(h)
  return { changed = true }
end
```

## Why this shape (one paragraph, to settle it)

`makac.exec` waits and captures — correct for `qemu-img`, `genisoimage`,
`kill`. A VM is not that: it must outlive the run unreaped-but-unblocked.
`spawn` is the *only* new process primitive needed: fork with stdio to
files, exit status observable, lifetime owned by nobody. Everything else —
detecting failure, waiting for readiness, escalating a stop — is plain Lua
loops over `status`/`fs.stat`/`pid_alive`/`qmp` with `time.sleep` gaps and
`time.now` deadlines, which is precisely what the workflow author can read
and the debugger can print from.
