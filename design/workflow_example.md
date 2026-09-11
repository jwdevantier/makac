# Workflow example (early sketch — superseded)

> **Status**: this is the original freehand sketch of what an nvme-test
> workflow could look like, written before the `qemu` package was specified.
> The details here are stale: `with.conf` is now `with.args` (design2/vm.md),
> the `{{ ... }}` templating does not exist (QEMU arguments are ordinary Lua
> arrays/tables, flattened per design2/vm.md), QMP command construction is a
> library (`pkgs:qemu/qmp`, design2/qmp.md), and VM identity is a `name`.
> See **design2/example_nvme_test.md** for the current form of this same loop.

```lua
-- helpers that I want to add to a utilities module

local merge = function(ts)
  local t = {}
  for _, tsrc in ipairs(ts) do
    for k, v in pairs(tsrc) do t[k] = v end
  end
  return t
end

local qmp_dev_add = function(driver, args)
  return {
    execute = "device_add",
    arguments = merge {
      args, {driver = driver}
    },
  }
end

local qmp_bdev_add = function(id, driver, args)
  return {
    execute = "blockdev-add",
    arguments = merge {
      args,
      {
	["node-name"] = id,
	driver = driver
      }
    },
  }
end

-- similar to gathering facts in Ansible *except*
-- 1. you decide if and WHEN to gather facts (sometimes some steps would alter facts)
-- 2. you decide which facts to gather by supplying a map of 'id' -> 'fact finder'.
--    (A fact finder is simply some code which returns a map of entries to be returned
--     as facts.)
facts = step {
  name = "Gather system facts",
  uses = "facts",
  with = {
    -- plug in the fact finders you want to run
    -- every <key>-><val> entry can be accessed as <res>.<key>
    -- and 'value' is a string to a builtin finder or some imported or custom fact finder
    finders = {
      os = "os", -- simple, builtin,
      env = "env"
    },
    -- optional: if omitted, run directly on runner
    -- target = vm1,
  }
}

-- TODO: define step which ensures OS img is built
-- TODO: define step which ensures raw test img is built

local vmconf = {}
if facts.out.facts.os.arch == "x86_64" then
  -- TODO: customize according to arch, expand base args(?)

  -- could split out and have some args be global/constant across all supported architectures.
  --
  -- should be implemented such that we can call functions which themselves return a table
  -- and that WE flatten it all
  vmconf = {
    "-nodefaults",

    "-machine",
    "q35,accel=kvm,kernel-irqchip=split",

    "-device",
    "intel-iommu,intremap=on",

    "-device",
    "virtio-rng-pci",

    "-netdev",
    "id=net0,hostfwd=tcp::{{.vm.ssh.port}}-:{{.vm.ssh.vm_port}}",

    "-device",
    "virtio-net-pci,netdev=net0",

    "-drive",
    -- NOTE: file-path is architecture-specific
    "if=pflash,format=raw,readonly=on,file=/home/nixos/repos/qemu/build/qemu-bundle/usr/local/share/qemu/edk2-x86_64-code.fd",

    "-drive",
    "if=pflash,format=raw,file=/home/nixos/repos/qqmgr/.qqmgr/vfio.toml/vm.vfio/ovmf-vars.fd",

    "-device",
    "pcie-root-port,id=pcie-root-port.0,chassis=1,slot=0",

    -- start OS drive devices
    "-device",
    "nvme-subsys,id=subsys.boot",

    "-device",
    "nvme,id=nvme-ctrl.1,serial=boot,bus=pcie-root-port.1,subsys=subsys.boot",

    "-drive",
    -- TODO: assign path to actual OS image
    "id=bdrv.boot,file=/home/nixos/mydrive.qcow2,format=qcow2,if=none,discard=unmap,media=disk",

    "-device",
    "nvme-ns,id=bs.boot,drive=bdrv.boot,nsid=1,bus=nvme-ctrl.1,bootindex=0"
    -- end OS drive devices
  }
end

local vm1_snap = step {
  -- name for step, optional, each backing action should define a default name
  -- e.g. in this case 'create VM snapshot'
  name = "create VM snapshot",
  uses = "qemu:savevm",
  with = {
    conf = vmconf,
  }
}

local vm = step {
  name = "resume vm",
  uses = "qemu:loadvm",
  with = {
    snapshot = vm1_snap.out.snapshot,
    -- like ansible.builtin.service, this (re-)starts the VM
    state = "restarted",
  }
}

-- TODO: define step sending file(s) to VM

local tstprg = step {
  name = "compile test program",
  uses = "shell",
  with = {
    target = vm.out.target,
    cmd = {"odin", "build", "tp4176", "-build-mode:test", "-out:/tmp/tp4176.test"},
  }
}

local opts_nvme_ns_4k = {
  logical_block_size = 4096,
  physical_block_size = 4096,
}

step {
  name = "",
  uses = "qemu:qmp/send",
  with = {
    vm = vm,
    commands = {
      -- test disk; 4K LBA
      qmp_dev_add("nvme-subsys", {
	id = "subsys.test",
      }),
      qmp_dev_add("nvme", {
	id = "nvme-ctrl.2",
	serial = "test",
	bus = "pcie-root-port.2",
	subsys = "subsys.test",
      }),
      qmp_bdev_add("bdev.test", "raw", {
	format = "raw",
	["if"] = "none",
	discard = "unmap",
	media = "disk",
	["read-only"] = "no",
	cache = "none",

	file = {
	  driver = "file",
	  -- TODO: assign real path
	  filename = "/tmp/boot.qcow2"
	}
      }),
      qmp_dev_add("nvme-ns", merge {
	{
	  id = "ns.test",
	  drive = "bdev.test",
	  nsid = 1,
	  nguid = "auto",
	  bus = "nvme-ctrl.2",
	},
	opts_nvme_ns_4k
      }),
    }
  }
}

-- TODO: wait/monitor for device to pop up on guest

local tst = step {
  name = "run test",
  uses = "shell",
  with = {
    cmd = {"/tmp/tp4176.test"},
    target = vm.out.target,
    env = {
      bdf = "0000:03:00.0"
    }
  },
}

step {
  name = "stop VM",
  uses = "qemu:vm",
  with = {
    handle = vm.out.handle,
    state = "stopped"
  }
}

```
