# Images: `qemu:img` and builders

An *image* is a disk-image artifact built from a spec and cached by hashes
of its inputs. One action, one `builder` key:

```lua
local img = step {
  name = "build fedora base image",
  uses = "qemu:img",
  with = {
    name    = "fedora-base",
    builder = "cloud-init",
    -- ... builder-specific keys
  },
}
-- img.out.path == "/abs/.../.makac/qemu/img/fedora-base/image"
```

`qemu:img` dispatches on `with.builder`: it looks the builder up and hands
it the `with` table plus a per-image state dir. Built-in builders: `raw`,
`cloud-init`. Custom builders are Lua functions (see "Custom builders").

## Common keys (all builders)

| key         | meaning                                                    |
|-------------|------------------------------------------------------------|
| `name`      | required; identity & state-dir key                         |
| `builder`   | required; `"raw"`, `"cloud-init"`, a registered name, or a function |
| `state_dir` | optional; default `makac.data_dir .. "/qemu/img/" .. name` |
| `env`       | optional; k→v map merged into the build environment        |
| `env_hook`  | optional; `function(env) -> env` (below)                    |
| `force`     | optional; bypass the manifest cache and rebuild            |

Every builder returns `out = { path = <abs path to the image> }` and
`changed = true` iff any stage ran.

## Caching

A builder is a pipeline of stages. Before a stage runs, the builder computes
a manifest — a hash over every input the stage consumes — and compares it
against the manifest file stored in the state dir by the previous run.
Match: the stage is skipped. Mismatch or missing: it runs and saves the new
manifest.

Concretely: editing a cloud-init template re-runs "render" and everything
after it, but does not re-download the base image or re-run `qemu-img
resize`.

## The environment and `env_hook`

Every builder assembles an environment (a k→v table used during the build —
most visibly by cloud-init templates) in three steps:

1. start from `with.env`;
2. if `with.env_hook` is present: `env = env_hook(env)`;
3. the result is the environment.

The hook is a Lua function. Read an ssh pubkey with `io.open`, derive a
password hash through `makac.exec`, generate an instance id — the function
returns the env it wants used.

## Builder `raw`

Empty disk images. Keys: `img_size = "1G"`, `format = "raw"` (default).
One stage: `qemu-img create` under a manifest of name/size/format.

## Builder `cloud-init`

A customized OS image from a stock cloud image, in five stages:

| stage       | does                                                            | manifest hashes             |
|-------------|-----------------------------------------------------------------|-----------------------------|
| 1. download | fetch base image (url + sha256) into the makac download cache   | url, sha256                 |
| 2. prepare  | copy base to state dir, `qemu-img resize` to `img_size`, create | base content, img_size      |
|             | the working overlay                                            |                             |
| 3. templates| render each `templates` entry with the env into the state dir   | env, each template's content |
| 4. iso      | `genisoimage -volid cidata ...` from rendered templates + `sources` | rendered files' content  |
| 5. customize| boot a throwaway VM (image as disk, ISO as cdrom); wait for it  | build_args + iso content     |
|             | to power itself off                                            |                             |

Required keys: `img_size`; `qemu_bin` and `build_args` (the command line of
the throwaway VM, flattened exactly as `qemu:vm`'s `args`);
`base_img = { url =, sha256 = }`; `templates = { { template = <file>,
output = <name in ISO> }, ... }` — at minimum user-data and meta-data.

### Templates

A template file renders with the env by one rule: `{{ name }}` in the file
expands to `env[name]`; a name absent from the env is a spec error naming
it. No further template syntax.

### The customize VM

The throwaway VM obeys `timeout_s` (default 600). Inside `build_args`, two
substitutions: `{{ img_self }}` (the working image) and
`{{ cloud_init_iso }}` (the ISO of stage 4).

The VM must power itself off: the cloud-init user-data ends with
`poweroff:` (or issues the shutdown). Timeout is a stage failure quoting the
VM's serial log and qemu-stderr, which stay in the state dir for inspection.

## Custom builders

```lua
local img = require("pkgs:qemu/img")

img.register_builder("my-builder",
  -- build
  function(with, ctx)   -- ctx = { state_dir, env, exec }
    -- produce ctx.state_dir .. "/image"
    return { path = ctx.state_dir .. "/image" }
  end,
  -- manifest (optional): what invalidates a rebuild
  function(with, ctx) return { size = with.img_size } end)
```

A builder is a *build* function and an optional *manifest* function. `ctx`
carries the state dir, the assembled env, and an `exec` helper. The two
built-ins are implemented with exactly this interface.

## `with.builder`: a name or a function

`with.builder` accepts a string — the id of a registered builder
(`"raw"`, `"cloud-init"`, or one registered via `register_builder`) — **or a
function**, in which case the function *is* the builder, used directly:

```lua
builder = function(with, ctx)
  -- ...produce ctx.state_dir .. "/image"
  return { path = ctx.state_dir .. "/image" }
end
```

A function builder may be paired with `with.builder_manifest = function(with,
ctx) -> table` for caching; a one-off function without a manifest runs every
time. Builders stay inside this package's surface: there is no export path
through the package system (actions and fetchers are core makac concepts;
images are not).

## Worked example: a cloud-init boot base

A complete `cloud-init` build spec — a Fedora base image customized with an
ssh key and a package set (the `bootbase` image from qqmgr's `base.toml`,
see `qqmgr_inspiration.md`):

```lua
local home = os.getenv("HOME")

local bootbase = step {
  name = "build bootbase (cloud-init) image",
  uses = "qemu:img",
  with = {
    name     = "bootbase",
    builder  = "cloud-init",
    qemu_bin = "/home/nixos/repos/qemu/build/qemu-system-x86_64",
    img_size = "10G",

    base_img = {
      url    = "https://mirror.netsite.dk/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2",
      sha256 = "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f",
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

    templates = {
      { template = "templates/fedora_nvme_base.tpl", output = "user-data" },
      { template = "templates/meta-data.tpl",        output = "meta-data" },
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
-- bootbase.out.path == <data_dir>/qemu/img/bootbase/image
```

The template files follow the design's single rule — `user-data` contains

```yaml
users:
  - name: root
    lock_passwd: false
    hashed_passwd: {{ root_password_hash }}
    ssh_authorized_keys:
      - {{ ssh_public_key }}
```

and `meta-data` likewise (`instance-id: {{ instance_id }}`,
`local-hostname: {{ hostname }}`).

Two reading notes:

* `-nographic` / `-serial ...` console options do not appear in
  `build_args`: the customize VM's serial is captured to the state dir per
  its contract, and a stdio chardev would contradict it.
* Two builds naming the same `base_img` url+sha256 (e.g. a `boot` and a
  `bootbase` image) share one download — stage 1 is content-cached.
