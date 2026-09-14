#cloud-config
users:
  - name: root
    lock_passwd: false
    hashed_passwd: {{ root_password_hash }}
    ssh_authorized_keys:
      - {{ ssh_public_key }}

disable_root: false
ssh_pwauth: true

packages:
  - gcc
  - g++
  - meson
  - ninja-build
  - lspci
  - nvme-cli
  - fio

# The guest-side topology the nvme tests rely on is image content
# (the makac.qemu package's design/example_nvme_test.md): vfio-pci
# available, the nvme driver
# blacklisted so hotplugged devices stay unbound until the test binds them.
write_files:
  - path: /etc/modules-load.d/vfio.conf
    content: |
      vfio
      vfio_iommu_type1
      vfio_pci
  - path: /etc/modprobe.d/blacklist-nvme.conf
    content: |
      blacklist nvme

runcmd:
  - sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 intel_iommu=on vfio-pci.ids=1b36:0010 modprobe.blacklist=nvme"/' /etc/default/grub
  - grub2-mkconfig -o /boot/grub2/grub.cfg

# The customize VM must power itself off (images.md, "The customize VM").
power_state:
  mode: poweroff
  timeout: 300
  condition: True
