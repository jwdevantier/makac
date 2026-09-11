# Fetcher
Every entry in the `.makac/packages.lua` file (see design/packages.md) must be fetched from the remote source.

The element will contain a `fetcher` key, identifying which fetcher to use.
A fetcher is a Lua function, which implements the means to actually fetch some remote package.

The program, makac, shall provide three default fetcher implementations:
* `fetchurl` - fetch a package over HTTP(s)
* `fetchgit` - fetch a package over Git
* `filesystem` - use a package from the local filesystem in place
  (the development fetcher)

Note that packages MAY provide additional fetchers, and that to use them you must prefix the exported fetcher with the id of the package that provides it, such as `mypkg:fetchcvs`.


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
`makac.lua` at its root. This is the development fetcher: edit the package,
re-run `makac run`, and your edits are live (loading reads from `path` itself).

```lua
{
  id = "mypkg.dev",
  fetcher = "filesystem",
  with = {
    path = "path/to/package",  -- relative to the project root (the dir holding .makac)
  }
}
```

At load time (`makac run`), packages are loaded in `packages.lua` **file order** —
the list is authoritative: an earlier package's actions/fetchers/lib are available
to later packages. A `filesystem` package's code root is its `with.path`; for other
fetchers it is `.makac/packages/<id>` (listed-but-not-fetched is a run-time error
telling you to `makac fetch` first).
