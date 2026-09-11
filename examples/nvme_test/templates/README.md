user-data template for the `bootbase` image (the cloud-init builder's one
rule applies: `{{ name }}` expands to `env[name]`, design2/images.md
"Templates"). Rendered into the cidata ISO as `user-data`.
