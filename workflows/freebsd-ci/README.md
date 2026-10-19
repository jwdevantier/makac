<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# freebsd-ci

Proof of concept: drive a **FreeBSD** guest with makac + makac.qemu, the
same way the Linux/QEMU tests are driven — build a customized base image,
boot it, run commands and move files inside over ssh.

It uses the official FreeBSD `BASIC-CI` image (a compressed raw download
with [nuageinit(7)](https://man.freebsd.org/cgi/man.cgi?nuageinit(7))
installed), customized at first boot via a NoCloud `cidata` seed
(`templates/`): an ssh key on the default `freebsd` user, sshd enabled,
then poweroff — after which the baked image is cached and every boot is a
no-customization startup.

## Run it

From **this directory** (it is the makac project root):

```sh
makac fetch
makac run freebsd-ci.lua
```

Tools needed on `PATH`: `qemu-system-x86_64` (or set `QEMU_BIN`),
`qemu-img`, `genisoimage`, `xz`, `ssh`. KVM is used when `/dev/kvm` is
available, plain emulation otherwise (slow but fine). An ssh keypair must
exist at `~/.ssh/id_ed25519` (or `id_rsa`) — the public half is installed
on the guest.

On NixOS, without installing anything:

```sh
nix shell nixpkgs#qemu nixpkgs#cdrkit \
  -c makac run freebsd-ci.lua
```

Useful variations:

```sh
MAKAC_IMG_VERBOSE=1 makac run freebsd-ci.lua   # watch the customize boot console
makac run freebsd-ci.lua stop                  # stop the VM afterwards
makac run freebsd-ci.lua restart               # force a fresh boot
```

Re-runs are cheap: the image build is stage-cached (download → extract →
prepare → templates → iso → customize), so a second `run` goes straight to
booting the VM.

## Why the customize boot disables nuageinit

Unlike cloud-init, nuageinit has **no first-boot / per-instance gating** —
it runs on every boot. So the customize `runcmd` ends with `sysrc
nuageinit_enable=NO` before `poweroff`: the throwaway customize boot applies
the seed once, then turns the image into a permanently bootable one. Leave
that line out and every boot of the baked image re-runs the runcmd and
powers itself straight back off (ssh never comes up).

## Debugging a boot

The VM runs with `-display none`, so the BIOS/loader/rc output goes to the
serial log; the kernel console stays on the (invisible) VGA console. The
serial log lives at
`.makac/qemu/<vm-name>/serial` while the VM is up (it is removed when the VM
stops or the step fails). To also mirror the *kernel* console onto serial,
add `console="ttyd0"` to the guest's `/boot/loader.conf`.

## Files

- `makac_project.lua` — wires `makac.qemu` (fetched from GitHub, tracking
  its `main` branch)
- `freebsd-ci.lua` — the whole workflow
- `templates/user-data.tpl` — nuageinit `#cloud-config` (must stay the
  first line): ssh key, sshd, DHCP, poweroff
- `templates/meta-data.tpl` — instance id + hostname

## Next steps (not here yet)

- graft the Zig tarball (`zig-x86_64-freebsd-…tar.xz`) into the cidata ISO
  via the image's `sources` key, install it in `runcmd`
- clone the makac repo in the guest and run the test battery
  (`zig build test`, `tests/blackbox/run.lua`, `tests/api/run.lua`)
- wire it into a GitHub Actions job (a Linux runner with `/dev/kvm` can
  run this exact workflow)
