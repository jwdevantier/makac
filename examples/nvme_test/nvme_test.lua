-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- The snapshot + hotplug NVMe test loop (design2/example_nvme_test.md):
-- boot a VM once, snapshot the booted state into its image, then run a
-- series of tests that each resume from the snapshot, hotplug an NVMe
-- device at a known BDF, bind it to vfio-pci in the guest, exercise it,
-- and tear down.
--
-- MANUAL ACCEPTANCE: run this against real QEMU/KVM from a directory wired
-- to the qemu package (packages.lua alias `qemu`). It downloads a Fedora
-- cloud image and needs /dev/kvm, qemu-img and genisoimage on PATH.
--
--   cd <your project> && makac run <path-to>/nvme_test.lua

local qmp = require("pkgs:qemu/qmp")

----------------------------------------------------------------------------
-- SITE-LOCAL VALUES — adjust to your host before running
----------------------------------------------------------------------------
local QEMU       = "/home/nixos/repos/qemu/build/qemu-system-x86_64" -- qemu_bin
local SSH_PORT   = 2090                    -- host-side ssh forward port
local BASE_URL   = "https://mirror.netsite.dk/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
local BASE_SHA256 = "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f"

-- VM_SSH_* globals make the ssh defaults ambient (vm.md, "SSH defaults")
VM_SSH_USER          = "root"
VM_SSH_IDENTITY_FILE = os.getenv("HOME") .. "/.ssh/id_ed25519"

local home = os.getenv("HOME")

-- the directory this workflow lives in, so template paths resolve no
-- matter which directory makac runs from (relative template paths are
-- resolved against makac's cwd, images.md)
local HERE = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$")) or "./"

-- §1  build the boot base (images.md, "Worked example: a cloud-init boot
--     base"), then boot once, wait for ssh, snapshot the booted state
local base_img = step {
  name = "build bootbase (cloud-init) image",
  uses = "qemu:img",
  with = {
    name     = "bootbase",
    builder  = "cloud-init",
    qemu_bin = QEMU,
    img_size = "10G",

    base_img = {
      url    = BASE_URL,     -- site-local: any Fedora cloud qcow2 + sha256
      sha256 = BASE_SHA256,
    },

    env = { hostname = "minos" },

    env_hook = function(env)   -- read a pubkey, set a password hash, an id
      local f = io.open(home .. "/.ssh/id_ed25519.pub")
      env.ssh_public_key = f and (f:read("a"):gsub("%s+$", "")) or ""
      if f then f:close() end
      env.root_password_hash = "$6$rounds=4096$dZvpjkhL4EwsC3Wi$lJ8pB0hy..."
      env.instance_id = "cloudvm-" .. os.time()
      return env
    end,

    templates = { -- resolved relative to this workflow file's directory
      { template = HERE .. "templates/fedora_nvme_base.tpl", output = "user-data" },
      { template = HERE .. "templates/meta-data.tpl",        output = "meta-data" },
    },

    build_args = {
      "-m", "2048",
      "-smp", "2",
      "-cpu", "host",
      "-enable-kvm",
      { "-drive",  "file={{ img_self }},if=virtio" },
      "-cdrom",    "{{ cloud_init_iso }}",
      "-boot",     "order=c",
      { "-device", "virtio-net-pci,netdev=net0" },
      { "-netdev", "user,id=net0" },
    },
  },
}
-- base_img.out.path == <data_dir>/qemu/img/bootbase/image

-- the machine configuration: q35 base plus pre-created PCIe root ports.
-- Q35 cannot hotplug root ports (qmp.md); they exist from boot, and the
-- snapshot freezes them into the base state. No NVMe devices yet.
local base_args = {
  "-nodefaults",
  { "-machine", "q35,accel=kvm,kernel-irqchip=split" },
  "-cpu", "host", "-smp", "2", "-m", "4096",
  { "-netdev", { user = true, id = "net0", hostfwd = "tcp::" .. SSH_PORT .. "-:22" } },
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

local base = step {
  name = "boot base VM",
  uses = "qemu:vm",
  with = {
    name = "testvm", state = "started", qemu_bin = QEMU,
    disk = { backing = base_img.out.path },  -- (from the qemu:img step above)
    args = base_args,
    ssh  = { port = SSH_PORT },
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
      ssh = { port = SSH_PORT },
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

-- the test invocations: site-local — the test binary must already exist
-- INSIDE the guest image (bootbase user-data installs/puts it on /tmp)
run_test("nvme-4k", { "/tmp/tp4176.test" })
