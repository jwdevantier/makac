#!/usr/bin/env makac
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- freebsd-ci.lua — build & boot a FreeBSD CI image, end to end:
--
--   1. qemu:img fetches the official FreeBSD BASIC-CI image (a compressed
--      raw download with nuageinit(7) installed), resizes it and
--      customizes it with a first boot driven by the cidata seed rendered
--      from templates/ — ssh key on the default "freebsd" user, sshd on.
--   2. qemu:vm boots the baked image with an ssh port forward.
--   3. shell steps prove the guest is alive (and a put/cat round-trip
--      shows the file-transfer path the real CI run will need).
--
-- Usage (from THIS directory — the project root):
--
--   makac fetch                        # once, and when makac_project.lua changes
--   makac run freebsd-ci.lua           # build the image, boot, verify
--   MAKAC_IMG_VERBOSE=1 makac run freebsd-ci.lua   # watch the customize boot
--   makac run freebsd-ci.lua stop      # stop the VM afterwards
--
-- Needs on PATH: qemu-system-x86_64 (or set QEMU_BIN), qemu-img,
-- genisoimage, xz, ssh. KVM is used when /dev/kvm is available, TCG
-- otherwise (slow but works).

-- configuration ----------------------------------------------------------

local FREEBSD_VERSION = "15.1"
local BASE_URL = ("https://download.freebsd.org/releases/CI-IMAGES/%s-RELEASE/amd64/Latest/FreeBSD-%s-RELEASE-amd64-BASIC-CI-ufs.raw.xz")
	:format(FREEBSD_VERSION, FREEBSD_VERSION)
-- sha256 of the .xz as published in the release's CHECKSUM.SHA256
local BASE_SHA256 = "908e735f18ba192eaf48c2703b549225c9b96e74e3784bd9278c7120b4139962"
local IMG_SIZE = "8G"

local VM_NAME = "freebsd-ci"
local SSH_PORT = 2223
local SSH_USER = "freebsd" -- nuageinit's default user (nuageinit(7))

local QEMU_BIN = os.getenv("QEMU_BIN") or "qemu-system-x86_64"
local KVM = makac.fs.stat("/dev/kvm") ~= nil
local ACCEL = "kvm:tcg" -- use KVM when available, fall back to emulation
local CPU = KVM and "host" or "max" -- "-cpu host" requires KVM

-- helpers ----------------------------------------------------------------

local function fail(fmt, ...)
	error(("freebsd-ci: " .. fmt):format(...), 0)
end

-- Locate an ssh keypair for guest access; returns (private_path, public_text).
local function ssh_keys()
	local home = assert(os.getenv("HOME"), "$HOME is not set")
	for _, name in ipairs({ "id_ed25519", "id_rsa" }) do
		local pub = ("%s/.ssh/%s.pub"):format(home, name)
		local f = io.open(pub)
		if f then
			local text = (f:read("a"):gsub("%s+$", ""))
			f:close()
			if text ~= "" then
				return ("%s/.ssh/%s"):format(home, name), text
			end
		end
	end
	fail("no ssh public key at ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub — " ..
		"create one (ssh-keygen -t ed25519); it is installed on the guest's '%s' user", SSH_USER)
end

-- The instance id persists across runs: a fresh one every run would
-- invalidate the template/iso stages (and make nuageinit re-run on an
-- already-customized image).
local function instance_id()
	local path = makac.data_dir .. "/freebsd-ci/instance-id"
	local f = io.open(path)
	if f then
		local s = (f:read("a"):gsub("%s+$", ""))
		f:close()
		if s ~= "" then return s end
	end
	makac.fs.mkdir_p(path:match("^(.*)/[^/]+$"))
	local id = "freebsd-ci-" .. makac.random_hex(8)
	local wf = assert(io.open(path, "w"))
	wf:write(id, "\n")
	wf:close()
	return id
end

-- stop / restart ---------------------------------------------------------

if arg[1] == "stop" then
	step {
		name = "stop " .. VM_NAME,
		uses = "qemu:vm",
		with = { vm = VM_NAME, state = "stopped" },
	}
	return
end

-- 1. build the base image --------------------------------------------------

local privkey, pubkey = ssh_keys()

local img = step {
	name = "build FreeBSD " .. FREEBSD_VERSION .. " CI base image",
	uses = "qemu:img",
	with = {
		name = "freebsd-" .. FREEBSD_VERSION .. "-ci-base",
		builder = "cloud-init",
		qemu_bin = QEMU_BIN,
		img_size = IMG_SIZE,
		timeout_s = 900,

		base_img = { url = BASE_URL, sha256 = BASE_SHA256 },

		env = { hostname = VM_NAME },
		env_hook = function(env)
			env.ssh_public_key = pubkey
			env.instance_id = instance_id()
			return env
		end,

		templates = {
			{ template = SCRIPT_DIR .. "/templates/user-data.tpl", output = "user-data" },
			{ template = SCRIPT_DIR .. "/templates/meta-data.tpl", output = "meta-data" },
		},

		build_args = {
			"-machine", "q35,accel=" .. ACCEL,
			"-cpu", CPU,
			"-smp", "2", "-m", "2048",
			"-drive", "file={{ img_self }},if=virtio,format=qcow2",
			"-cdrom", "{{ cloud_init_iso }}",
			"-boot", "order=c",
			"-netdev", "user,id=net0",
			"-device", "virtio-net-pci,netdev=net0",
		},
	},
}

-- 2. boot it ---------------------------------------------------------------

local vm = step {
	name = "boot " .. VM_NAME,
	uses = "qemu:vm",
	with = {
		vm = VM_NAME,
		state = arg[1] == "restart" and "restarted" or "started",
		qemu_bin = QEMU_BIN,
		disk = { backing = img.out.path },
		ssh = {
			port = SSH_PORT,
			user = SSH_USER,
			identity_file = privkey,
			-- a fresh throwaway guest every bake: no known-hosts ceremony
			options = { StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null" },
		},
		wait_ssh = { timeout_s = 420, interval_s = 3 },
		args = {
			"-machine", "q35,accel=" .. ACCEL,
			-- with -display none the BIOS/loader/boot output goes to the
			-- serial log; the kernel console stays on vt (console=ttyd0 in
			-- /boot/loader.conf would mirror the kernel onto serial too).
			"-boot", "menu=off,splash-time=0,strict=on",
			"-cpu", CPU,
			"-smp", "2", "-m", "2048",
			"-drive", "id=bdrv.boot,file={{ disk }},format=qcow2,if=none",
			"-device", "virtio-blk-pci,drive=bdrv.boot,bootindex=0",
			"-netdev", ("user,id=net0,hostfwd=tcp::%d-:22"):format(SSH_PORT),
			"-device", "virtio-net-pci,netdev=net0",
			"-display", "none",
		},
	},
}
local target = assert(vm.out.target, "no ssh target — was wait_ssh disabled?")

-- 3. prove the guest is alive ----------------------------------------------

--- Run argv in the guest, print what it said, return the captured output.
local function guest(name, argv)
	local r = step { name = name, uses = "shell", target = target, with = { cmd = argv } }
	local out = r.out or {}
	if (out.stdout or "") ~= "" then io.stdout:write(out.stdout) end
	if (out.stderr or "") ~= "" then io.stderr:write(out.stderr) end
	return out
end

local uname = guest("guest: uname", { "uname", "-a" })
if not (uname.stdout or ""):find("FreeBSD") then
	fail("expected a FreeBSD guest, got: %s", uname.stdout or "")
end
guest("guest: whoami", { "id" })
guest("guest: root filesystem", { "df", "-h", "/" })

-- the file-transfer path: upload a marker, read it back
local marker = tostring(makac.fs.mktemp_file("freebsd-ci-"))
makac.fs.write_file(marker, "hello from makac\n")
target:put(marker, "hello-from-makac.txt")
os.remove(marker)
guest("guest: read uploaded file", { "cat", "hello-from-makac.txt" })

io.stdout:write(([[

OK — FreeBSD %s guest is up and reachable.
  vm:  %s (leave it running to poke at it, or: makac run freebsd-ci.lua stop)
  ssh: ssh -p %d -i %s -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null %s@127.0.0.1
]]):format(FREEBSD_VERSION, VM_NAME, SSH_PORT, privkey, SSH_USER))
