#!/data/data/com.termux/files/usr/bin/bash
# Build the Bionic AArch64 `codex` from upstream source + patches/.
#
#   VERSION=0.160.0 scripts/build.sh
#
# Runs on a Termux device or inside termux-docker (CI). Output: dist/.
set -Eeuo pipefail
# Report the failing command (a bare `set -e` exit leaves no trace in the CI log).
# EXIT, not ERR: ERR also fires for commands that are expected to exit non-zero.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
DIST="${DIST:-$ROOT/dist}"
SRC="$WORK/codex"
PYJ() { python3 -c "import json,sys; print(json.load(open('$ROOT/versions.json'))['$1'])"; }

VERSION="${VERSION:-$(PYJ version)}"
UPSTREAM="$(PYJ upstream)"
TAG="$(PYJ tag_prefix)$VERSION"
RUST_MIN="$(PYJ rust_min)"

# Release-profile knobs. LTO off keeps peak memory low on phones and 4-core CI.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-off}"
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}"
export CARGO_PROFILE_RELEASE_STRIP=true
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/target}"

echo "::group::Preflight"
for t in cargo rustc git clang cmake protoc python3 pkg-config tar sha256sum; do
  command -v "$t" >/dev/null || { echo "build: missing tool: $t" >&2; exit 1; }
done
# protoc-bin-vendored has no Android binary; patch 0001 makes build.rs honor PROTOC.
export PROTOC="${PROTOC:-$(command -v protoc)}"

RUSTC_VER="$(rustc --version | awk '{print $2}')"
if [ "$(printf '%s\n%s\n' "$RUST_MIN" "$RUSTC_VER" | sort -V | head -1)" != "$RUST_MIN" ]; then
  echo "build: rustc $RUSTC_VER < $RUST_MIN (std File::lock is unsupported on Android before 1.98)" >&2
  exit 1
fi
echo "rustc $RUSTC_VER, upstream $UPSTREAM $TAG"
echo "::endgroup::"

echo "::group::Fetch $UPSTREAM $TAG"
mkdir -p "$WORK"
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" = "$TAG" ]; then
  git -C "$SRC" checkout -q -- .   # drop previously applied patches / lock rewrite
else
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$TAG" "https://github.com/$UPSTREAM.git" "$SRC"
fi
UPSTREAM_SHA="$(git -C "$SRC" rev-parse HEAD)"
echo "$TAG -> $UPSTREAM_SHA"
echo "::endgroup::"

echo "::group::Apply patches"
shopt -s nullglob
PATCHES=("$ROOT"/patches/*.patch)
for p in "${PATCHES[@]}"; do
  git -C "$SRC" apply --check "$p" || { echo "build: patch does not apply: $(basename "$p")" >&2; exit 1; }
  git -C "$SRC" apply "$p"
  echo "applied $(basename "$p")"
done
echo "::endgroup::"

echo "::group::cargo build --release"
cd "$SRC/codex-rs"
cargo build --release -p codex-cli --bin codex --message-format short
echo "::endgroup::"

# The tag's Cargo.lock carries stale 0.0.0 workspace stamps, so --locked cannot
# be used. Prove that cargo rewrote nothing but those stamps (no dependency moved).
BAD="$(git diff -U0 -- Cargo.lock | grep -E '^[-+][^-+]' \
  | grep -v -E "^[-+]version = \"(0\.0\.0|$VERSION)\"$" || true)"
if [ -n "$BAD" ]; then
  echo "build: Cargo.lock changed beyond workspace version stamps:" >&2
  echo "$BAD" | head -20 >&2
  exit 1
fi

echo "::group::Package"
rm -rf "$DIST"; mkdir -p "$DIST/pkg"
install -m755 "$CARGO_TARGET_DIR/release/codex" "$DIST/pkg/codex"
cp "$SRC/LICENSE" "$SRC/NOTICE" "$DIST/pkg/"
tar -C "$DIST/pkg" -czf "$DIST/codex-termux-aarch64.tar.gz" codex LICENSE NOTICE
cp "$DIST/pkg/codex" "$DIST/codex"
(cd "$DIST" && sha256sum codex-termux-aarch64.tar.gz > codex-termux-aarch64.tar.gz.sha256)

VERSION="$VERSION" TAG="$TAG" UPSTREAM_SHA="$UPSTREAM_SHA" RUSTC_VER="$RUSTC_VER" \
ROOT="$ROOT" DIST="$DIST" python3 - <<'PY'
import hashlib, json, os, pathlib, platform
root, dist = pathlib.Path(os.environ["ROOT"]), pathlib.Path(os.environ["DIST"])
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
doc = {
    "codex": os.environ["VERSION"],
    "upstream_tag": os.environ["TAG"],
    "upstream_commit": os.environ["UPSTREAM_SHA"],
    "rustc": os.environ["RUSTC_VER"],
    "target": "android-aarch64",
    "architecture": platform.machine(),
    "patches": {p.name: sha(p) for p in sorted((root / "patches").glob("*.patch"))},
    "binary_sha256": sha(dist / "codex"),
    "tarball_sha256": sha(dist / "codex-termux-aarch64.tar.gz"),
}
(dist / "build-manifest.json").write_text(json.dumps(doc, indent=2) + "\n")
PY
rm -rf "$DIST/pkg"
ls -la "$DIST"
echo "::endgroup::"
echo "build: OK: codex $VERSION"
