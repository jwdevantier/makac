# qqmgr feature summary

[qqmgr](~/repos/qqmgr) — "Quick QEMU Manager" — is a Go CLI for managing
QEMU VMs in development. This document lists its features; the package in
`design2/` is based on it.

## Commands

* `start <vm>` — resolve the VM's config, create the runtime dir, delete stale
  logs, launch QEMU detached with auto-injected args, stdout/stderr to files.
* `stop <vm>` — graceful QMP `system_powerdown`, poll every 1s up to a
  timeout (default 20s, `--timeout`), then if `--force` (default true) a
  force kill; clean up runtime files afterwards.
* `status <vm>` — report name, pid, pidfile, running/alive, qmp-connected,
  ssh port/config, serial/qmp/monitor paths, plus `query-status` details.
  JSON output supported.
* `ssh <vm> [cmd]`, `put`, `get` — shell/file transfer over ssh using a
  generated per-VM config, with ControlMaster connection caching.
* `serial` / `stdout` / `stderr` — tail the VM's serial file and QEMU logs.
* `gdb <vm>` — launch gdb on the QEMU process with the VM's args loaded.
* `img list`, `img build <name>` — image management.
* config discovery: `./qqmgr.toml` then `~/.config/qqmgr/conf.toml`.

## Per-VM runtime directory

`.qqmgr/<config-basename>/vm.<name>/` holding well-known files: `pid`,
`serial`, `qmp.socket`, `monitor.socket`, `ssh.conf`, `qemu-stdout.log`,
`qemu-stderr.log`. Auto-injected args:

```
-pidfile  <dir>/pid
-monitor  unix:<dir>/monitor.socket,server,nowait
-serial   file:<dir>/serial
-qmp      unix:<dir>/qmp.socket,server,nowait
```

User args containing `-pidfile`, `-monitor`, `-serial` or `-qmp` are rejected.

## Status probing

QMP (`query-status`) is authoritative when reachable: its `running` boolean
is the answer and the full status map is reported as details. When not
reachable, fall back to the pidfile + `kill(pid, 0)` for liveness.

## QMP client

One connection per operation; `SendCommand` takes a command map
(`{execute, arguments}`), replies decode from JSON; events accumulate on the
connection.

## Configuration

TOML. `[vm.<name>]` holds `cmd` (array of strings, whitespace-split into
argv at launch). Go-template variables: globals from `[vars]`, VM-local from
`[vm.<name>.vars]`, special `{{.vm.ssh.port}}` / `{{.vm.ssh.vm_port}}`, and
`{{.img.<name>}}` resolving to a built image's path.
`[vm.<name>.ssh]` holds `port` / `vm_port`. `[ssh]` keys go verbatim into
the generated per-VM `ssh.conf`.

## Images

`[img.<name>]`, builders `raw` and `cloud-init`.

### env assembly

global `[vars]` + `[img.<name>.env]` (overriding) + optional env hook.
The hook is an external program: env passed as JSON on stdin, resulting env
read as JSON on stdout.

### raw builder

`img_size` → `qemu-img create -f raw <image> <size>`.

### cloud-init builder

Five stages, each cached by a manifest of input hashes
(`*.manifest.json` in the state dir):

1. download base image (`base_img.url`, `base_img.sha256sum`) into a
   content-addressed cache
2. copy to state dir, `qemu-img resize` to `img_size`, create working
   qcow2 overlay
3. render `templates` entries (`template` file + `output` name;
   Go-template over the env) into the state dir
4. `genisoimage -volid cidata -joliet -graft-points` an ISO from the
   rendered files plus extra `sources` (cached downloads grafted in)
5. boot a throwaway VM (`qemu_bin` + `build_args`; image as disk
   `{{.img_self}}`, ISO as cdrom `{{.cloud_init_iso}}`), wait for it to
   power itself off; 10-minute timeout

The final artifact is `<state>/image`.
