#cloud-config
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# nuageinit(7) user-data for the FreeBSD BASIC-CI image (NoCloud, cidata).
# NOTE: nuageinit only parses the file when it STARTS with "#cloud-config" —
# keep that the first line.
#
# The customize boot (qemu:img stage 6) runs this at first boot: it installs
# our ssh key on the default "freebsd" user, enables sshd, and then DISABLES
# nuageinit itself and powers off.
#
# Why disable nuageinit: unlike cloud-init, nuageinit has no first-boot or
# per-instance gating — it runs on EVERY boot. Left enabled, every boot of
# the baked image would re-run this runcmd and power the machine straight
# back off. Disabling it here is what turns the throwaway customize boot
# into a permanent, bootable image: subsequent boots come up clean with
# sshd running and the key already in place.
hostname: {{ hostname }}
ssh_pwauth: false
ssh_authorized_keys:
  - {{ ssh_public_key }}
network:
  ethernets:
    vtnet0:
      dhcp4: true
runcmd:
  - sysrc sshd_enable=YES
  - service sshd start
  - sysrc nuageinit_enable=NO
  - poweroff
