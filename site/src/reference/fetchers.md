<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Fetchers

A **fetcher** is a Lua function that knows how to bring a package into the
project. Every entry in `.makac/packages.lua` names a fetcher (its `fetcher`
key) and passes it arguments (its `with` table). Fetching happens only when you
run `makac fetch` — never automatically during `makac run`.

The [Concepts: Packages & the data directory](../concepts/packages.md) page
explains the package model; this page is the precise fetcher reference.

## The fetcher contract

A fetcher is a function `fn(spec, dest_dir)`:

- `spec` is the **full** entry table from `packages.lua` (so the fetcher's
  arguments live under `spec.with`, and it can read `spec.id` for error
  messages).
- `dest_dir` is where the package's code must end up:
  `<data_dir>/packages/<id>/` for every fetcher except `filesystem`, which
  uses the source path in place.

A fetcher that fails raises (or errors); `makac fetch` aborts the whole run on
the first failure, with a message naming the package.

Fetchers are registered by name. The three built-ins are always available:
`fetchurl`, `fetchgit`, `filesystem`. Packages may contribute more (exported as
`fetchers` in their `makac.lua`); to use a package-provided fetcher, prefix it
with the providing package's id: `mypkg:fetchcvs`. A fetcher name that does not
resolve is an error naming the package and the unknown fetcher.

## `fetchurl`

Fetches a package over HTTP(S), verifies the downloaded bytes against a SHA256
hash, and unpacks it:

```lua
{
    id = "somepkg",
    fetcher = "fetchurl",
    with = {
        -- required: URL to fetch (http/https; anything curl can GET)
        url = "https://example.com/some-file.tgz",

        -- required: 64 lowercase hex chars; the fetched bytes are ALWAYS
        -- verified against this — a mismatch is a hard error
        sha256 = "0123...",

        -- required: how to unpack. Either the string "tar" (extract with the
        -- system tar into dest), or a custom function(args, dst_dir) that
        -- receives the downloaded file's path as args.archive
        unpacker = "tar",
    },
}
```

The download is cached under the data directory (`<data_dir>/cache`), keyed by
the URL: re-fetching the same URL is served from cache (and re-verified when a
checksum is given — a corrupt entry is dropped and re-fetched).

## `fetchgit`

Fetches a package from a Git repository:

```lua
{
    id = "somepkg",
    fetcher = "fetchgit",
    with = {
        -- required: git URL to clone
        url = "https://github.com/user/some-repo.git",

        -- optional: commit hash, tag, or branch to check out.
        -- Omitted: the repository's default branch.
        rev = "v1.2.0",
    },
}
```

The clone **keeps its `.git` directory**, so `makac fetch` is re-runnable: a
later fetch into an existing work tree fetches and re-checks-out instead of
re-cloning. Git environment variables from the caller's environment
(`GIT_INDEX_FILE`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_OBJECT_DIRECTORY`) are
scrubbed from the subprocesses. A non-zero git exit is a fetch failure and
aborts the run.

## `filesystem`

Uses a package from the local filesystem **in place** — nothing is copied,
`dest` is unused. This is the development fetcher: edit the package, re-run
`makac run`, and your edits are live.

```lua
{
    id = "mypkg.dev",
    fetcher = "filesystem",
    with = {
        -- required: path to the package's directory (must contain a
        -- makac.lua at its root). Relative paths resolve against the
        -- project root (the directory holding the .makac data dir), so
        -- workflows work from any subdirectory. Absolute paths work too.
        path = "path/to/package",
    },
}
```

"Fetching" only validates: the path must be an existing directory with a
`makac.lua` at its root — a typo'd path is caught by `makac fetch`, not later
at run time. Loading reads from the path itself.

## Fetching order and chaining

Entries in `packages.lua` are fetched in **file order**. The list is
authoritative: an earlier package may provide a fetcher that a later entry
uses (e.g. `mypkg:fetchcvs`). The built-in registry is prepopulated with
`fetchurl`/`fetchgit`/`filesystem`; an unknown fetcher name is an error naming
the package and the fetcher.

> **Note:** fetcher *chaining within a single fetch run* — a package fetched
> during `makac fetch` becoming usable as the fetcher for a *later* entry in
> that same run — is not implemented yet. Packages are loaded (and their
> fetchers registered) during `makac run`, so a package-provided fetcher is
> available to fetch *other* packages on a subsequent `makac fetch` run.

## Where fetched code lives

Every fetcher except `filesystem` puts the package's code at
`<data_dir>/packages/<id>/`. A listed-but-not-fetched package is a run-time
error at `makac run`, telling you to run `makac fetch` first. A `filesystem`
package's code root is its `with.path` itself.
