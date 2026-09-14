user-data template for the `bootbase` image (the cloud-init builder's one
rule applies: `{{ name }}` expands to `env[name]` (the makac.qemu
package's design/images.md, "Templates"). Rendered into the cidata ISO
as `user-data`.
