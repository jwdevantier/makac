#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Rewrite the static version fallbacks in vm/version.odin. Used by the release
# workflow, and runnable by hand:
#
#   scripts/bump-version.sh <major> <minor>
#
# The `#config` fallbacks are the single place the version lives; a release
# build may still override them with -define:MAKAC_VERSION_*. Fails (non-zero)
# if the arguments are not non-negative integers or if the file does not end up
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
file="$root/vm/version.odin"
if [ ! -f "$file" ]; then
  echo "bump-version: $file not found" >&2
  exit 1
fi

sed -i -E \
  "s/^(VERSION_MAJOR[[:space:]]*::[[:space:]]*#config\(MAKAC_VERSION_MAJOR,[[:space:]]*)[0-9]+\)/\1${major})/" \
  "$file"
sed -i -E \
  "s/^(VERSION_MINOR[[:space:]]*::[[:space:]]*#config\(MAKAC_VERSION_MINOR,[[:space:]]*)[0-9]+\)/\1${minor})/" \
  "$file"

if ! grep -qE "^VERSION_MAJOR[[:space:]]*::[[:space:]]*#config\(MAKAC_VERSION_MAJOR,[[:space:]]*${major}\)" "$file"; then
  echo "bump-version: failed to set MAJOR=${major}" >&2
  exit 1
fi
if ! grep -qE "^VERSION_MINOR[[:space:]]*::[[:space:]]*#config\(MAKAC_VERSION_MINOR,[[:space:]]*${minor}\)" "$file"; then
  echo "bump-version: failed to set MINOR=${minor}" >&2
  exit 1
fi

echo "bump-version: vm/version.odin -> ${major}.${minor}"
