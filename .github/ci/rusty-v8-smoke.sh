#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux-docker (see .github/workflows/rusty-v8.yml) before a rusty_v8 archive is
# published: links it into tests/v8-smoke with Termux's own Rust and clang, the way
# scripts/build.sh links Codex, then runs that with and without the JIT.
#
#   rusty-v8-smoke.sh DIR    DIR holds scripts/build-rusty-v8.sh's output
set -Eeuo pipefail
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V8_OUT="$(cd "${1:?usage: rusty-v8-smoke.sh DIR}" && pwd)"
OUT="$ROOT/work/v8-smoke"

echo "::group::Install Termux packages"
# Same repository pinning as bionic-build.sh.
echo 'deb https://packages.termux.dev/apt/termux-main stable main' > "$PREFIX/etc/apt/sources.list"
export TERMUX_PKG_NO_MIRROR_SELECT=1
apt_options=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg update -y
pkg upgrade -y "${apt_options[@]}"
for attempt in 1 2 3; do
  pkg install -y "${apt_options[@]}" rust clang binutils && break
  [ "$attempt" = 3 ] && { echo "pkg install failed after $attempt attempts" >&2; exit 1; }
  sleep 20
  pkg update -y
done
rustc --version
clang --version | head -1
echo "::endgroup::"

echo "::group::Build tests/v8-smoke against the archive"
cat "$V8_OUT/BUILD-INFO.txt"
(cd "$V8_OUT" && sha256sum --check SHA256SUMS)
mkdir -p "$ROOT/work"
WORK="$ROOT/work"
# Put the archive where cargo-env.sh looks, the layout build.sh downloads to; source it again
# once the archive is there, for the hash.
V8_VERSION="$(sed -nE 's/^rusty_v8 ([0-9.]+) .*/\1/p' "$V8_OUT/BUILD-INFO.txt")"
export WORK V8_VERSION
# shellcheck source=../../scripts/cargo-env.sh
source "$ROOT/scripts/cargo-env.sh"
rm -rf "$WORK/rusty_v8"
mkdir -p "$WORK/rusty_v8"
cp -R "$V8_OUT" "$V8_DIR"
# shellcheck source=../../scripts/cargo-env.sh
source "$ROOT/scripts/cargo-env.sh"
export CARGO_TARGET_DIR="$WORK/v8-smoke-target"
# The v8 crate must be the archive's version.
SMOKE="$WORK/v8-smoke-src"
rm -rf "$SMOKE"
cp -R "$ROOT/tests/v8-smoke" "$SMOKE"
sed -i -E "s/^v8 = \{ version = \"=[0-9.]+\"/v8 = { version = \"=$V8_VERSION\"/" "$SMOKE/Cargo.toml"
grep -F "\"=$V8_VERSION\"" "$SMOKE/Cargo.toml"
cargo build --release --manifest-path "$SMOKE/Cargo.toml"
mkdir -p "$OUT"
cp "$CARGO_TARGET_DIR/release/v8-smoke" "$OUT/"
ls -la "$OUT/v8-smoke"
readelf -d "$OUT/v8-smoke" | grep NEEDED
echo "::endgroup::"

status=0
for mode in jit jitless; do
  echo "::group::v8-smoke ($mode)"
  args=()
  [ "$mode" = jitless ] && args=(--jitless)
  "$OUT/v8-smoke" "${args[@]}" 2>&1 | tee "$OUT/smoke-$mode.txt" || status=1
  echo "::endgroup::"
done
exit "$status"
