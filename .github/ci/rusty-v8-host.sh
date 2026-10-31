#!/usr/bin/env bash
# Prepares the x86_64 runner for scripts/build-rusty-v8.sh (see .github/workflows/rusty-v8.yml):
# Clang 21 for bindgen and sccache. Exports WORK and SCCACHE_DIR to the following steps; the
# paths stay fixed so that sccache entries match across runs.
set -Eeuo pipefail
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

# The checkout, the toolchains V8 downloads and the build take ~30 GB.
df -h / /mnt
sudo mkdir -p /mnt/v8
sudo chown "$(id -u):$(id -g)" /mnt/v8
echo "WORK=/mnt/v8/work" >> "$GITHUB_ENV"
echo "SCCACHE_DIR=/mnt/v8/sccache" >> "$GITHUB_ENV"

echo "::group::Clang 21 (rusty_v8's bindgen needs libclang 21.1+)"
. /etc/os-release
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor |
  sudo tee /etc/apt/trusted.gpg.d/llvm-snapshot.gpg >/dev/null
echo "deb http://apt.llvm.org/$VERSION_CODENAME/ llvm-toolchain-$VERSION_CODENAME-21 main" |
  sudo tee /etc/apt/sources.list.d/llvm-21.list
sudo apt-get update -q
sudo apt-get install -yq --no-install-recommends clang-21 libclang-21-dev
echo "LIBCLANG_PATH=/usr/lib/llvm-21/lib" >> "$GITHUB_ENV"
echo "::endgroup::"

echo "::group::sccache"
SCCACHE_VERSION=v0.19.0
name="sccache-$SCCACHE_VERSION-x86_64-unknown-linux-musl"
curl -fsSL "https://github.com/mozilla/sccache/releases/download/$SCCACHE_VERSION/$name.tar.gz" |
  tar -xz -C "$RUNNER_TEMP"
sudo install -m 755 "$RUNNER_TEMP/$name/sccache" /usr/local/bin/sccache
sccache --version
echo "::endgroup::"
