#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Run the whole end-to-end suite against one built makac binary. Every test
# here drives the real CLI against its own throwaway project and is hermetic
# (no network), so this is safe to run in a build/release container and on
# foreign base images.
#
#   run_all.sh /path/to/makac
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: run_all.sh <makac-binary>" >&2; exit 2; }
bin="$(readlink -f "$1")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$here/smoke-test.sh" "$bin"
bash "$here/package-fetchers.sh" "$bin"

echo "e2e: all tests passed"
