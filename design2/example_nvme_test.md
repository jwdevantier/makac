# Worked example: the snapshot + hotplug NVMe test loop

The end-to-end shape the package exists for (from
`nvme-test-final/sources/test_vm_setup_idea.md`): boot a VM once, snapshot
the booted state into its image, then run a series of tests that each resume
from the snapshot, hotplug an NVMe device at a known BDF, bind it to
vfio-pci in the guest, exercise it via `/dev/vfio/<group>`, and tear down.

```lua
local qmp = require("pkgs:qemu/qmp")

local QEMU = "/home/nixos/repos/qemu/build/qemu-system-x86_64"

-- VM_SSH_* globals make the ssh defaults ambient (vm.md, "SSH defaults")
VM_SSH_USER          = "root"
VM_SSH_IDENTITY_FILE = os.getenv("HOME") .. "/.ssh/id_ed25519"

-- the machine configuration: q35 base plus pre-created PCIe root ports.
-- Q35 cannot hotplug root ports (qmp.md); they exist from boot, and the
-- snapshot freezes them into the base state. No NVMe devices yet.
local base_args = {
  "-nodefaults",
  { "-machine", "q35,accel=kvm,kernel-irqchip=split" },
  "-cpu", "host", "-smp", "2", "-m", "4096",
  { "-netdev", { user = true, id = "net0", hostfwd = "tcp::2090-:22" } },
  { "-device", "virtio-net-pci,netdev=net0" },
  { "-device", "pcie-root-port,id=root0,chassis=1,slot=0" },
  { "-device", "pcie-root-port,id=root1,chassis=2,slot=0" },
  { "-device", "pcie-root-port,id=root2,chassis=3,slot=0" },
  -- boot disk: overlay over the built image (vm.md)
  { "-drive",  "id=bdrv.boot,file={{ disk }},format=qcow2,if=none" },
  { "-device", "nvme-subsys,id=boot_subsys" },
  { "-device", "nvme,id=nvme-boot-ctrl,serial=boot,subsys=boot_subsys" },
  { "-device", "nvme-ns,id=nvme-boot,drive=bdrv.boot,nsid=1,bus=nvme-boot-ctrl,bootindex=0" },
}

-- §1  boot once, wait for ssh, snapshot the booted state, stop
local base_img = step {
  name = "build boot image",
  uses = "qemu:img",
  with = { name = "bootbase", builder = "cloud-init", --[[ as images.md ]] },
}

local base = step {
  name = "boot base VM",
  uses = "qemu:vm",
  with = {
    name = "testvm", state = "started", qemu_bin = QEMU,
    disk = { backing = base_img.out.path },  -- (from the qemu:img step above)
    args = base_args,
    ssh  = { port = 2090 },
  },
}

local snap = step {
  name = "snapshot booted state",
  uses = "qemu:savevm",
  with = { vm = base.out.handle, tag = "base_snapshot" },
}

step { -- base has done its work; its snapshot is in the image
  uses = "qemu:vm",
  with = { name = "testvm", state = "stopped" },
}

-- §2-5  per test: resume, hotplug at a known BDF, bind vfio-pci, run, drop
local function run_test(test_name, test_args)
  local vm = step {
    name = "resume for test " .. test_name,
    uses = "qemu:loadvm",
    with = {
      name = "testvm",    -- same run_dir the snapshot was taken on; resumed
                          -- serially, each test re-resuming with "restarted"
      qemu_bin = QEMU, args = base_args,
      snapshot = snap.out.snapshot,             -- -loadvm base_snapshot
      state = "restarted",
      ssh = { port = 2090 },
    },
  }

  step {   -- hotplug: synchronous at QMP; guest discovers asynchronously
    name = "attach nvme0",
    uses = "qemu:qmp/send",
    with = { vm = vm.out.handle, commands = {
      qmp.dev_add("nvme", { id = "nvme0", bus = "root0", addr = "0.0" }),
      -- addr as a STRING: fixes the BDF the guest will see
    } },
  }

  step {   -- wait for guest-side appearance at the deterministic BDF
    uses = "shell",
    with = { target = vm.out.target, cmd = { "sh", "-c",
      "while ! lspci -nn | grep -q '0000:03:00.0'; do sleep 0.1; done" } },
  }

  step {   -- bind to vfio-pci (guest's nvme driver is blacklisted in the image)
    uses = "shell",
    with = { target = vm.out.target, cmd = { "sh", "-c", [[
      addr=0000:03:00.0
      echo "$addr" > /sys/bus/pci/devices/$addr/driver/unbind || true
      echo vfio-pci > /sys/bus/pci/devices/$addr/driver_override
      echo "$addr" > /sys/bus/pci/drivers/vfio-pci/bind
    ]] } },
  }

  step {   -- the actual test
    name = "run " .. test_name,
    uses = "shell",
    with = { target = vm.out.target, cmd = test_args },
  }

  step {   -- hot-unplug; poll QMP for the unplug event, then retire the buffer
    uses = "qemu:qmp/send",
    with = { vm = vm.out.handle, commands = {
      { execute = "device_del", arguments = { id = "nvme0" } },
    } },
  }
  local p = step { uses = "qemu:qmp/poll",
                   with = { vm = vm.out.handle, timeout_s = 10 } }
  assert(p.out.events[1].name == "DEVICE_DELETED")
  step { uses = "qemu:qmp/consume",
         with = { vm = vm.out.handle, n = #p.out.events } }

  step { uses = "qemu:vm", with = { name = "testvm", state = "stopped" } }
end

run_test("nvme-4k", { "/tmp/tp4176.test" })
```

Mapping to the recipe:

| recipe step                              | here                                                        |
|------------------------------------------|-------------------------------------------------------------|
| boot once, `savevm base_snapshot`        | `qemu:vm` (wait_ssh) → `qemu:savevm tag="base_snapshot"`     |
| each test: same args + `-loadvm`         | `qemu:loadvm` with `base_args` + `snapshot = snap.out.snapshot` |
| root ports pre-created, no NVMe at boot  | `base_args` builds the ports; topology frozen by the snapshot |
| `device_add` with `addr = "0.0"` (string) | `qemu:qmp/send` + `qmp.dev_add` (qmp.md, "Hotplug notes")   |
| guest polls `lspci` for the known BDF    | `shell` step on `vm.out.target`                             |
| unbind/driver_override/bind vfio-pci      | `shell` step on the target                                 |
| run via `/dev/vfio/<group>`              | the test `shell` step                                       |
| destroy VM, repeat                       | `qemu:vm state="stopped"`; the next test's `state="restarted"` re-resumes |

* Snapshot locality: `savevm` writes into the VM's writable disk, which for
  an overlay-booted VM is `<run_dir>/disk.qcow2` — so resumed instances use
  the *same run dir (same name)*. The recipe's "unique PID files per test
  instance" applies to *concurrent* instances; for those, use distinct
  names and make the snapshot live in a shared backing image rather than a
  per-run-dir overlay.
* The guest's nvme-driver blacklist is image content (`user-data` of the
  `bootbase` image), not a step.
