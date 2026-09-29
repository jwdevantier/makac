# Fetcher
Every entry in the `inputs` table of `makac_project.lua` (see design/packages.md) must be fetched from the remote source.

The entry contains a `fetcher` key, identifying which fetcher to use.
A fetcher is a Lua function, which implements the means to actually fetch some remote package.

The program, makac, shall provide three default fetcher implementations:
* `fetchurl` - fetch a package over HTTP(s)
* `fetchgit` - fetch a package over Git
* `filesystem` - use a package from the local filesystem in place
  (the development fetcher)

Packages provide additional fetchers via their manifest's `fetchers` table, and
those fetchers ARE usable in `makac_project.lua`: `makac fetch` works through the
inputs as a worklist — an input is fetched as soon as its fetcher name resolves,
and every fetched package's fetchers immediately join the registry (under each
alias wired to it, `bar:svn`-style), so a package fetched earlier in the run can
provide the fetcher for a later input. A pass with no progress is a hard error
naming, per remaining input, the fetcher it waits for (unwired provider, typo, or
a fetcher cycle).

## The fetcher contract

A fetcher is an object with two methods:

```lua
{
  -- storage key: a PURE hash of the semantically relevant 'with' fields. The
  -- output identifies what gets fetched semantically: same key <=> same
  -- content. Fixed length, safe charset ([A-Za-z0-9._-]). Fields that do not
  -- change what is fetched (e.g. fetchurl's unpacker — post-processing of
  -- sha256-pinned bytes) MUST NOT participate.
  key = function(with) return "myfetcher-" .. makac.sha256(...) end,

  -- materialize the package at dest (an empty/absent dir under
  -- .makac/packages/<key>/). spec is the full input entry (spec.with,
  -- spec.label), dest the destination path.
  fetch = function(spec, dest) ... end,
}
```

A fetcher object is also callable (`fetcher(spec, dest)` dispatches to `.fetch`),
which keeps workflow-time use natural. An in-place fetcher (like `filesystem`)
sets `in_place = true` instead of `key`: nothing is stored or pruned.

A fetcher with no `key` (a plain function, or an object without one) may still be
called from workflows but cannot fetch inputs — an input using one fails with a
clear error. Inline fetchers in the project file must be objects with a `key`
(a literal string is allowed for one-offs).

## `fetchurl`
Fetches some package over HTTP(s), verifies it against the provided SHA256 hash and uncompresses it according to the `unpacker`.

```lua
{
  url = "https://example.com/some-file.tgz",
  -- required, must match sha of the fetched package
  sha256 = "...",
  -- required, supported:
  -- "tar" -- uncompress with tar
  -- custom uncompressor:
  -- function(args, dst_dir) ... end
  unpacker = "tar"
}
```

## `fetchgit`
Fetches some Git repository. Use `rev` to pin to a particular hash or tag, or just define a branch to track.
```lua
{
  url = "https://github.com/user/some-repo.git",
  -- fetch tip of `rev`, may be a commit hash, a tag or a branch
  rev = "...",
}
```

## `filesystem`
The package lives on the local filesystem and is used *in place* — `makac fetch`
copies nothing; it only validates that `path` is an existing directory with a
`makac_package.lua` at its root. This is the development fetcher: edit the package,
re-run `makac run`, and your edits are live (loading reads from `path` itself).

```lua
return {
  inputs = {
    mypkg = {
      fetcher = "filesystem",
      with = {
        path = "path/to/package",  -- relative to the project root (the dir holding .makac)
      },
    },
  },
  packages = { mypkg = "mypkg" },
}
```

In-place inputs take no part in storage or pruning: at load they resolve
directly from `with.path`, live (there is nothing to go stale — the source IS
the package).

## Storage, load-time resolution, and pruning

Fetched packages land in `.makac/packages/<storage key>/` — content-addressed:
the key comes from the fetcher's `key` method, so "same arguments" means "same
directory", two revs of one repo are two directories, and nothing else (labels,
project layout, other packages) participates.

Loading (`makac load_packages`, hence every `makac run`) **recomputes** the key
from the input entry — the same worklist as fetch, minus the materialization:
an input resolves once its fetcher is registered (built-ins immediately,
package-provided ones as provider manifests run). The directory of a stored
input is its key: present means up to date; absent means the input was never
fetched or its arguments changed since — either way the error tells you to
`makac fetch`. A `filesystem` package's code root is its `with.path` itself.

After a successful fetch run, makac prunes: any `.makac/packages/` entry whose
key no current input produced is stale and is removed. (The `makac.download`
cache under `.makac/cache/` is a separate layer below, keyed by URL.)


