#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
#
# Build a release makac binary inside a throwaway AlmaLinux 9 container, so
# that the resulting binary's glibc floor (2.34) is set by Alma rather than by
# whatever host happens to be building. Run as root, e.g.:
#
#   docker run --rm -v "$PWD:/work" -w /work -e MAJOR -e MINOR \
#     almalinux:9@sha256:... bash /work/scripts/build-in-container.sh amd64
#
# MAJOR and MINOR must be in the environment (the release workflow passes them
# through). Produces ./makac-linux-<target> in the mounted working directory and
# asserts that Lua 5.4 is statically embedded rather than dynamically linked.
set -euo pipefail

target="${1:-}"
case "$target" in
  amd64)
    odin_arch=amd64
    odin_sha=40f38b462f30914c7f07271c56c8b4b7a7a6e5d82789c8165f75ab569c3b96cc
    expect_machine=x86_64
    ;;
  arm64)
    odin_arch=arm64
    odin_sha=01fc4938cb79d82064bf0b20c4745732e74cc508fdcb6669fa1fa29be8a7d8d4
    expect_machine=aarch64
    ;;
  *)
    echo "usage: $0 <amd64|arm64>" >&2
    exit 2
    ;;
esac

: "${MAJOR:?MAJOR must be set}"
: "${MINOR:?MINOR must be set}"

# Keep in sync with the pins already used by .github/workflows/test.yml.
ODIN_VERSION="dev-2026-06"
LUA_VERSION="5.4.7"
LUA_SHA256="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"

machine="$(uname -m)"
if [ "$machine" != "$expect_machine" ]; then
  echo "build-in-container: target ${target} but container architecture is ${machine}" >&2
  exit 1
fi

odin_root=/opt/odin
build_root=/opt/makac-build
mkdir -p "$build_root"

echo "==> installing build dependencies"
# The AlmaLinux 9 base image ships `curl-minimal`, which already provides the
# `curl` CLI but conflicts with the full `curl` package; don't request `curl`
# here. Everything else we need is in the default-enabled BaseOS/AppStream
# repos (clang/llvm/gcc in AppStream; make/file/binutils in BaseOS).
dnf install -y --setopt=install_weak_deps=False \
  clang llvm gcc make binutils tar gzip file
command -v curl >/dev/null || { echo "build-in-container: curl is missing" >&2; exit 1; }

echo "==> installing Odin ${ODIN_VERSION} (${odin_arch})"
if [ ! -x "${odin_root}/odin" ]; then
  cd "$build_root"
  curl -fsSL -o odin.tar.gz \
    "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-${odin_arch}-${ODIN_VERSION}.tar.gz"
  echo "${odin_sha}  odin.tar.gz" | sha256sum -c -
  mkdir -p "$odin_root"
  # The tarball's top-level directory is a nightly-stamped name; strip it.
  tar -xzf odin.tar.gz -C "$odin_root" --strip-components=1
fi
"${odin_root}/odin" version

echo "==> building Lua ${LUA_VERSION} (static)"
cd "$build_root"
if [ ! -f "lua-${LUA_VERSION}/src/liblua.a" ]; then
  curl -fsSL -o "lua-${LUA_VERSION}.tar.gz" "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
  echo "${LUA_SHA256}  lua-${LUA_VERSION}.tar.gz" | sha256sum -c -
  tar -xzf "lua-${LUA_VERSION}.tar.gz"
  make -C "lua-${LUA_VERSION}/src" -j"$(nproc)" liblua.a CC=clang
fi
lua_a="${build_root}/lua-${LUA_VERSION}/src/liblua.a"

# amd64: the vendored binding links the toolchain's bundled archive by explicit
# path (vendor/lua/5.4/linux/liblua54.a), so overwrite it with our build.
install -m 0644 "$lua_a" "${odin_root}/vendor/lua/5.4/linux/liblua54.a"
# arm64 and other Linux arches: the binding emits `-llua5.4`, so drop the same
# archive on the linker's default search path. Nothing else in the image
# provides a shared liblua, so `-llua5.4` resolves to this static archive.
install -m 0644 "$lua_a" /usr/lib64/liblua5.4.a

echo "==> building makac (${target})"
cd /work
rm -f "makac-linux-${target}"
"${odin_root}/odin" build . -out:"makac-linux-${target}" \
  -define:MAKAC_VERSION_MAJOR="${MAJOR}" \
  -define:MAKAC_VERSION_MINOR="${MINOR}"

echo "==> verifying Lua is statically embedded"
if readelf -d "makac-linux-${target}" | grep -qi 'NEEDED.*liblua'; then
  echo "build-in-container: liblua is dynamically linked" >&2
  exit 1
fi
file "makac-linux-${target}"
echo "==> ok: makac-linux-${target} reports $(./"makac-linux-${target}" --version)"
