<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: CC0-1.0 -->

# Fetchers

A **fetcher** knows how to bring a package into the project. Every entry in
`makac_project.lua`'s `inputs` names a fetcher (its `fetcher` key) and passes it
arguments (its `with` table). Fetching happens only when you run `makac fetch` —
never automatically during `makac run`.

The [Concepts: Packages](../concepts/packages.md) page
explains the package model; this page is the precise fetcher reference.

## The fetcher contract

A fetcher is an object:

- `fetch(spec, dest)` — **required**. Materialize the package at `dest`, a
  fresh path under `<data_dir>/packages/<key>/`. `spec` is the **full** input
  entry: arguments under `spec.with`, the input's label under `spec.label`.
  Raise on failure — `makac fetch` aborts on the first raise, naming the input.
- `key(with)` — **required unless `in_place`**. A *pure* function hashing the
  semantically relevant `with` fields into the storage key: fixed length, safe
  charset (`[A-Za-z0-9._-]`). "Same key" must mean "same content", so fields
  that cannot change the result (e.g. `fetchurl`'s unpacker choice —
  post-processing of sha256-pinned bytes) must **not** participate. A literal
  string works as a constant key.
- `in_place = true` — **optional**. The package is used from its source
  location; `key` is omitted, nothing is stored and nothing is pruned (what
  `filesystem` does).

The object is also *callable* — `fetcher(spec, dest)` dispatches to `.fetch` —
so workflow-time use stays natural. A bare function may be registered and called
from workflows, but cannot fetch an input: without a `key` there is no storage
key, and an input using one errors clearly at load.

Fetchers are registered by name. The three built-ins are always available:
`fetchurl`, `fetchgit`, `filesystem`. Packages contribute more by exporting them
from their `makac_package.lua` (see [Writing a fetcher](#writing-a-fetcher)); in a
project file they are usable as `<alias>:<name>`, and the fetch worklist retries
inputs as new fetchers appear.

## Built-in fetchers

### `fetchurl`

Fetches a package over HTTP(S), verifies the downloaded bytes against a SHA256
hash, and unpacks it:

```lua
inputs = {
    somepkg = {
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
    },
}
```

The download is cached under the data directory (`<data_dir>/cache`), keyed by
the URL: re-fetching the same URL is served from cache (and re-verified when a
checksum is given — a corrupt entry is dropped and re-fetched).

### `fetchgit`

Fetches a package from a Git repository:

```lua
inputs = {
    somepkg = {
        fetcher = "fetchgit",
        with = {
            -- required: git URL to clone
            url = "https://github.com/user/some-repo.git",

            -- optional: commit hash, tag, or branch to check out.
            -- Omitted: the repository's default branch.
            rev = "v1.2.0",
        },
    },
}
```

The clone **keeps its `.git` directory**, so `makac fetch` is re-runnable: a
later fetch into an existing work tree fetches and re-checks-out instead of
re-cloning. Git environment variables from the caller's environment
(`GIT_INDEX_FILE`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_OBJECT_DIRECTORY`) are
scrubbed from the subprocesses. A non-zero git exit is a fetch failure and
aborts the run.

### `filesystem`

Uses a package from the local filesystem **in place** — nothing is copied,
`dest` is unused. This is the development fetcher: edit the package, re-run
`makac run`, and your edits are live.

```lua
inputs = {
    mypkg = {
        fetcher = "filesystem",
        with = {
            -- required: path to the package's directory (must contain a
            -- makac_package.lua at its root). Relative paths resolve against the
            -- project root (the directory holding the .makac data dir), so
            -- workflows work from any subdirectory. Absolute paths work too.
            path = "path/to/package",
        },
    },
}
```

"Fetching" only validates: the path must be an existing directory with a
`makac_package.lua` at its root — a typo'd path is caught by `makac fetch`, not
later at run time. Loading reads from the path itself.

## Fetching order: the worklist

Inputs are processed as a worklist: each input is fetched as soon as its
fetcher resolves in the registry. After every fetch the fetched package's
manifest runs — validating it and merging its `fetchers` into the registry
under every alias wired to that input. So a package fetched earlier in the
run can provide the fetcher a later input names (`bar:svn`); the registry
drives the order, there is no static dependency graph. A full pass without
progress is a hard error listing, per remaining input, what it waits for —
which is also how fetcher cycles surface.

## Where fetched code lives

Every fetcher except in-place ones puts the package's code at
`<data_dir>/packages/<storage key>/` (content-addressed; the key comes from
the fetcher's `key` method). At the end of a run `makac fetch` prunes any
`packages/` entry no current input produced. Loading recomputes keys from the
inputs: a wired-but-not-fetched package (directory missing — never fetched, or
edited since) is a run-time error at `makac run`, telling you to run
`makac fetch`. A `filesystem` package's code root is its `with.path` itself.

## Writing a fetcher

Implement `key` and `fetch`, export the object under a name, and point an input
at `<alias>:<name>`:

```lua
-- makac_package.lua (at the providing package's root)
return {
    fetchers = {
        fetchcvs = {
            -- identity: a pure hash of the fields that determine the checkout
            key = function(w)
                return "cvs-" .. makac.sha256("cvs\0" .. w.root .. "\0" .. tostring(w.tag)):sub(1, 32)
            end,
            -- materialize at dest; spec is the full input entry
            fetch = function(spec, dest)
                local w = spec.with
                local r = makac.exec({
                    "cvs", "-d", w.root, "export", "-r", w.tag or "HEAD",
                    "-d", dest, w.module,
                })
                if r.code ~= 0 then
                    error("fetchcvs: " .. tostring(w.module) .. ": " .. r.stderr, 0)
                end
            end,
        },
    },
}
```

```lua
-- makac_project.lua
return {
    inputs = {
        -- the package that provides the fetcher, fetched normally...
        mycvs = { fetcher = "fetchgit",
                  with = { url = "https://example.com/mycvs.git", rev = "v1" } },
        -- ...then used by another input in the same run:
        legacy = { fetcher = "mycvs:fetchcvs",
                   with = { root = ":pserver:example.com:/cvs", module = "widget", tag = "v1.2" } },
    },
    packages = { mycvs = "mycvs", legacy = "legacy" },
}
```

The provider must be wired under an alias (here `mycvs`) — a provider fetcher is
named `<alias>:<name>`, so renaming the alias renames it for every input that
uses it.
