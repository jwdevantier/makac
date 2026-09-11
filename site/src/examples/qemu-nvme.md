<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# QEMU + NVMe: boot, snapshot, hotplug, test

This is the workflow class makac was built for: exercise hardware — here QEMU's
NVMe device code — inside a real VM, end to end. The pattern is:

1. **build** a bootable disk image (a cloud-init-customized OS),
2. **boot** the VM once,
3. **snapshot** the booted state (RAM + devices) into the image,
4. for each test: **resume** from the snapshot in seconds (no re-boot),
5. **hotplug** an NVMe controller via QMP while the guest runs,
6. watch the guest **pick it up**, then **assert** its shape,
7. **tear down**.

The VM work is done by the [makac QEMU package](../qemu-package.md), loaded as
a package. The workflow below is *paraphrased and simplified* from makac's own
end-to-end NVMe test — the shapes are real, the site-local values (paths, ssh
keys, image URLs) are placeholders.

## Setting up the QEMU package

Declare the package in `.makac/packages.lua` and fetch it:

```lua
-- .makac/packages.lua
return {
    {
        id = "qemu",
        fetcher = "fetchgit",
        with = {
            url = "https://github.com/jwdevantier/makac.qemu",
            rev = "main",
        },
    },
}
```

```bash
$ makac fetch
defined packages (#1):
  1. qemu (fetcher: fetchgit)
fetching qemu via fetchgit...
fetched qemu
```

## 1–2. Build an image and boot once

First a blank 1 GiB raw disk and a cloud-init-customized OS image. The `qemu:img`
action is *idempotent*: it builds by content manifest, so re-runs (and every
workflow that re-declares the same image) are fast no-ops.

```lua
local raw = step {
    name = "image raw-1",
    uses = "qemu:img",
    with = {
        name     = "raw-1",
        builder  = "raw",
        img_size = "1G",
    },
}

local bootbase = step {
    name = "image bootbase",
    uses = "qemu:img",
    with = {
        name     = "bootbase",
        builder  = "cloud-init",
        img_size = "10G",
        -- any cloud-init-capable base image + its sha256
        base_img = {
            url    = "https://example.com/fedora-cloud-base.qcow2",
            sha256 = "<64 hex chars>",
        },
        env = { hostname = "testbox" },
        -- env_hook = function(env) ... end,   -- e.g. inject an ssh pubkey
        -- templates = { { template = "...", output = "..." } },
        -- build_args = { ... },                -- customize the build VM
    },
}
```

Now boot a VM from the built image. Two details matter for the later hotplug:

- **No NVMe devices at boot** — this particular workflow hotplugs them, and the
  snapshot must not contain any.
- **PCIe root ports are pre-created** — the Q35 machine cannot create root ports
  dynamically, so the hotplug *target* (a free port) must exist from the start.

```lua
local SSH_PORT = 2201   -- host-side ssh forward (any free port you pick)

local vm = step {
    name = "boot testvm",
    uses = "qemu:vm",
    with = {
        name     = "testvm",
        qemu_bin = "/path/to/qemu-system-x86_64",   -- site-local
        args = {
            "-machine", "q35,accel=kvm",
            "-cpu", "host",
            "-smp", "2",
            "-m", "1024",
            { "-netdev", { user = true, id = "net0", hostfwd = "tcp::" .. SSH_PORT .. "-:22" } },
            { "-device", "virtio-net-pci,netdev=net0" },
            { "-device", "pcie-root-port,id=root0,chassis=1,slot=0" },
            { "-device", "pcie-root-port,id=root1,chassis=2,slot=0" },
            -- boot disk: a qcow2 overlay over the built image, on plain
            -- virtio (see the note above — no NVMe anywhere at boot)
            { "-drive", "file={{ disk }},format=qcow2,if=virtio" },
        },
        disk = { backing = bootbase.out.path },
        ssh  = { port = SSH_PORT },
    },
}
```

`qemu:vm` waits for ssh and hands back the VM as `out.target` — an ordinary
remote target that later `shell` steps can run against — plus `out.handle` and
`out.pid`.

## 3. Snapshot the booted state

`qemu:savevm` captures the running VM's state (RAM + devices) into its disk
image under a tag, via QMP:

```lua
local snap = step {
    name = "snapshot booted state",
    uses = "qemu:savevm",
    with = {
        vm  = vm.out.handle,
        tag = "base_snapshot",
    },
}
assert(snap.err == nil, tostring(snap.err))
```

The snapshot lives in the image, so the base VM has done its job. Stop it —
every later test resumes from the snapshot instead of booting:

```lua
step {
    name = "stop testvm",
    uses = "qemu:vm",
    with = { name = "testvm", state = "stopped" },
}
```

## 4. Resume from the snapshot (seconds, not minutes)

Each test resumes the snapshot. Because the VM resumes from a saved state, the
guest is back at a known point and ssh-reachable **far faster than a fresh
boot** — and the test starts exactly where the snapshot was taken:

```lua
local resumed = step {
    name = "resume from snapshot",
    uses = "qemu:loadvm",
    with = {
        name     = "testvm",
        qemu_bin = "/path/to/qemu-system-x86_64",  -- site-local
        args     = vm_args,                        -- same machine as before
        snapshot = snap.out.snapshot,              -- -loadvm base_snapshot
        state    = "restarted",                    -- fresh qemu process
        ssh      = { port = SSH_PORT },
    },
}
local target = resumed.out.target
```

`qemu:loadvm` runs QEMU with `-loadvm <tag>`, giving a **new** qemu process
(`resumed.out.pid` differs from the original) that reuses the run directory and
its overlay — which is exactly what keeps the snapshot alive across the
close-and-resume.

## 5–6. Hotplug an NVMe controller and watch the guest pick it up

The hotplug is a QMP `device_add` — synchronous as far as QEMU is concerned, but
the *guest* discovers the new device asynchronously. First, a per-run copy of
the blank raw disk: the guest will write to the hotplugged namespace, and the
shared 1 GiB blank must not be mutated:

```lua
local ns_img = "./run/mini-ns.img"
assert(makac.exec({ "cp", raw.out.path, ns_img }).code == 0,
    "copy raw-1 for the hotplug ns")
```

The commands are built with the package's `qmp` library:

```lua
local qmp = require("pkgs:qemu/qmp")

local hot = step {
    name = "hotplug nvme controller",
    uses = "qemu:qmp/send",
    with = {
        vm = resumed.out.handle,
        commands = {
            qmp.bdev_add("test-bdev", "raw", {
                ["read-only"] = false,
                cache = { direct = true },
                file  = { driver = "file", filename = ns_img },
            }),
            qmp.dev_add("nvme", {
                id     = "nvme0",
                bus    = "root1",        -- the pre-created root port
                addr   = "0.0",          -- as a STRING: pins the guest BDF
                drive  = "test-bdev",    -- nsid 1 realized with the device
                logical_block_size  = 4096,
                physical_block_size = 4096,
            }),
        },
    },
}
for i, r in ipairs(hot.out.results) do
    assert(r.error == nil, ("hotplug command %d failed: %s"):format(i, tostring(r.error)))
end
```

Then poll the guest over ssh until the device shows up (a bounded retry loop —
plain Lua around a `shell` step):

```lua
local found = false
local last = ""
for _ = 1, 30 do
    local s = step {
        name = "poll guest for nvme",
        uses = "shell",
        target = target,
        with = {
            cmd = { "sh", "-c", "ls /dev/nvme* 2>/dev/null; dmesg | grep -i nvme | tail -2" },
            ignore_exit_code = true,  -- device may not exist yet; that's data
        },
    }
    last = s.out.stdout or ""
    if last:match("/dev/nvme0") then
        found = true
        break
    end
    makac.time.sleep(2 * makac.time.ns_per_s)
end
assert(found, "hotplugged NVMe never appeared in the guest:\n" .. last)
print("guest sees the hotplugged NVMe")
```

## Assert its shape

Once the guest has picked the device up, assert exactly what we care about — one
controller, and the namespace presenting as 1 GiB with 4K logical sectors:

```lua
local ctrl = step {
    name = "guest: controller count",
    uses = "shell",
    target = target,
    with = { cmd = { "sh", "-c", "lspci -nn | grep -c '\\[0108\\]'" } },
}
assert(tonumber(ctrl.out.stdout:gsub("%s+", "")) == 1, "expected 1 NVMe controller")

local disk = step {
    name = "guest: namespace shape",
    uses = "shell",
    target = target,
    with = {
        cmd = { "lsblk", "-b", "-n", "-d", "-o", "NAME,SIZE,LOG-SEC", "/dev/nvme0n1" },
    },
}
local _, size, logsec = disk.out.stdout:match("^(%S+)%s+(%d+)%s+(%d+)")
assert(tonumber(size) == 1073741824, "expected 1 GiB, got " .. tostring(size))
assert(tonumber(logsec) == 4096, "expected 4K sectors, got " .. tostring(logsec))
print(("hotplugged ns: %d bytes, %dB logical sectors"):format(size, logsec))
```

## 7. Tear down

Hot-unplug in reverse order (QMP `device_del` is an asynchronous guest eject),
then stop the VM cleanly:

```lua
step {
    name = "unplug nvme controller",
    uses = "qemu:qmp/send",
    with = {
        vm = resumed.out.handle,
        commands = {
            { execute = "device_del", arguments = { id = "nvme0" } },
        },
    },
}
-- optional: qemu:qmp/poll until the DEVICE_DELETED event, then qemu:qmp/consume
-- to retire it from the event buffer

step {
    name = "stop testvm",
    uses = "qemu:vm",
    with = { name = "testvm", state = "stopped" },
}
```

A clean `state = "stopped"` is a graceful ACPI powerdown (the package escalates
to QMP `quit`, then `kill -9`, if the guest wedges) and removes the VM's run
directory. makac also closes every target when the workflow finishes — even on
failure — so no ssh control masters are left behind.

## The payoff

- The **snapshot** turns "one long boot" into "many instant test starts" — each
  test begins at a known, deterministic machine state.
- **Hotplug over QMP** means the machine under test can be reconfigured while
  running, and the workflow *observes* the guest reacting to it.
- Every primitive is plain Lua: the whole per-test loop (resume → hotplug →
  wait → assert → teardown) can be factored into a `function run_test(name)` and
  called with different arguments — that is exactly how makac's own end-to-end
  suite is structured.
