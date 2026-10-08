#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Rewrite the version constants in src/version.zig (and the package version in
# build.zig.zon). Used by the release workflow, and runnable by hand:
#
#   scripts/bump-version.sh <major> <minor>
#
# src/version.zig is the single source of the version reported by
# `makac --version`; build.zig.zon carries the same pair for the package
# manager, padded to a full semantic version (`MAJOR.MINOR.0`) because Zig's
# manifest parser rejects a two-component version. Fails (non-zero) if the
# arguments are not non-negative integers or if the files do not end up
# holding exactly the requested pair.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <major> <minor>" >&2
  exit 2
fi
major=$1
minor=$2

for v in "$major" "$minor"; do
  case "$v" in
    '' | *[!0-9]*)
      echo "bump-version: '$v' is not a non-negative integer" >&2
      exit 2
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root/src/version.zig"
zon_file="$root/build.zig.zon"

[ -f "$version_file" ] || { echo "bump-version: $version_file not found" >&2; exit 1; }
[ -f "$zon_file" ] || { echo "bump-version: $zon_file not found" >&2; exit 1; }

sed -i -E \
  -e "s/^(pub const version = \")[0-9]+\.[0-9]+(\";)/\1${major}.${minor}\2/" \
  -e "s/^(pub const major = )[0-9]+(;)/\1${major}\2/" \
  -e "s/^(pub const minor = )[0-9]+(;)/\1${minor}\2/" \
  "$version_file"

# Only the `.version` key is the package version; `.minimum_zig_version`
# is a different key and is never touched. Zig requires a full semantic
# version (three components), so pad the pair with a zero patch.
sed -i -E "s/^([[:space:]]*\.version = \")[0-9]+(\.[0-9]+)*(\".*)$/\1${major}.${minor}.0\3/" "$zon_file"

fail=0
grep -qE "^pub const version = \"${major}\.${minor}\";" "$version_file" || { echo "bump-version: failed to set version in src/version.zig" >&2; fail=1; }
grep -qE "^pub const major = ${major};" "$version_file" || { echo "bump-version: failed to set major in src/version.zig" >&2; fail=1; }
grep -qE "^pub const minor = ${minor};" "$version_file" || { echo "bump-version: failed to set minor in src/version.zig" >&2; fail=1; }
grep -qE "^[[:space:]]*\.version = \"${major}\.${minor}\.0\"," "$zon_file" || { echo "bump-version: failed to set version in build.zig.zon" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1

echo "bump-version: src/version.zig -> ${major}.${minor}, build.zig.zon -> ${major}.${minor}.0"
