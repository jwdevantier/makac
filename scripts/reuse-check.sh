#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# REUSE license-compliance check (https://reuse.software).
#
#   scripts/reuse-check.sh              # lint the whole project
#   scripts/reuse-check.sh --quiet      # extra arguments go to `reuse lint`
#
# Runs through the flake's `lint` dev shell, so the pinned `reuse` is used
# regardless of the ambient environment. Falls back to a `reuse` already on
# PATH when Nix is unavailable (e.g. inside `nix develop .#lint` itself).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if command -v nix >/dev/null 2>&1; then
  exec nix develop "$root#lint" --command reuse lint "$@"
fi

if command -v reuse >/dev/null 2>&1; then
  echo "reuse-check: nix not found; using the ambient reuse" >&2
  exec reuse lint "$@"
fi

echo "reuse-check: need 'nix' (preferred) or 'reuse' on PATH" >&2
exit 1
