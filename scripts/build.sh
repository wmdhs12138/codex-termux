#!/data/data/com.termux/files/usr/bin/bash
# Build the Bionic AArch64 `codex` from upstream source + patches/.
#
#   VERSION=0.166.0 scripts/build.sh
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
# Where the rusty-v8-v* releases are published.
REPO="${CODEX_TERMUX_REPO:-$(PYJ repo)}"

echo "::group::Preflight"
for t in cargo rustc git clang cmake protoc python3 pkg-config tar sha256sum curl; do
  command -v "$t" >/dev/null || { echo "build: missing tool: $t" >&2; exit 1; }
done

RUSTC_VER="$(rustc --version | awk '{print $2}')"
SORTED_RUST="$(printf '%s\n%s\n' "$RUST_MIN" "$RUSTC_VER" | sort -V)"
if [ "${SORTED_RUST%%$'\n'*}" != "$RUST_MIN" ]; then
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

echo "::group::Code Mode's V8 (rusty_v8 archive)"
# rusty_v8 publishes no Android archive. .github/workflows/rusty-v8.yml builds one for the exact
# `v8` version upstream pins and publishes it as the release $V8_TAG; cargo-env.sh names the
# release and the files, this downloads and verifies them once.
unset V8_VERSION
# shellcheck source=cargo-env.sh
source "$ROOT/scripts/cargo-env.sh"
[ -n "$V8_VERSION" ] || { echo "build: no exact v8 pin in codex-rs/Cargo.toml" >&2; exit 1; }
if ! (cd "$V8_DIR" 2>/dev/null && sha256sum --check --quiet SHA256SUMS 2>/dev/null); then
  V8_URL="https://github.com/$REPO/releases/download/$V8_TAG"
  rm -rf "$V8_DIR"; mkdir -p "$V8_DIR"
  for f in SHA256SUMS "${RUSTY_V8_ARCHIVE##*/}" "${RUSTY_V8_SRC_BINDING_PATH##*/}"; do
    curl -fsSL --retry 3 -o "$V8_DIR/$f" "$V8_URL/$f" || {
      echo "build: cannot download $V8_URL/$f; run the rusty-v8 workflow for $V8_VERSION" >&2
      exit 1
    }
  done
  (cd "$V8_DIR" && sha256sum --check SHA256SUMS)
fi
# Again, now that SHA256SUMS is there: it pins RUSTY_V8_ARCHIVE_SHA256.
# shellcheck source=cargo-env.sh
source "$ROOT/scripts/cargo-env.sh"
echo "$V8_TAG, archive sha256 $RUSTY_V8_ARCHIVE_SHA256"
echo "::endgroup::"

echo "::group::cargo build --release"
cd "$SRC/codex-rs"
cargo build --release -p codex-cli --bin codex -p codex-code-mode-host --bin codex-code-mode-host \
  --message-format short
echo "::endgroup::"

# The tag's Cargo.lock carries stale 0.0.0 workspace stamps, so --locked cannot be used, and
# patch 0021 moves v8 from a git fork to crates.io. Prove that no dependency changed version.
python3 - "$VERSION" <<'PY'
import subprocess, sys, tomllib
version = sys.argv[1]
orig = tomllib.loads(subprocess.check_output(["git", "show", "HEAD:codex-rs/Cargo.lock"], text=True))
new = tomllib.load(open("Cargo.lock", "rb"))

def versions(doc):
    out = {}
    for package in doc["package"]:
        v = package["version"]
        if "source" not in package and v in ("0.0.0", version):  # workspace member stamp
            v = "<workspace>"
        out.setdefault(package["name"], set()).add(v)
    return out

a, b = versions(orig), versions(new)
# A version replaced by another one is an upgrade; pure additions or pure removals (a crate
# that nothing uses any more) are expected.
bumped = {n: (sorted(a[n] - b[n]), sorted(b[n] - a[n])) for n in a.keys() & b.keys()
          if a[n] - b[n] and b[n] - a[n]}
added, removed = sorted(set(b) - set(a)), sorted(set(a) - set(b))
print(f"Cargo.lock: {len(added)} crates added ({', '.join(added[:6])}...), "
      f"{len(removed)} dropped ({', '.join(removed) or '-'})")
if bumped:
    print("build: Cargo.lock bumped existing dependencies:", bumped, file=sys.stderr)
    sys.exit(1)
PY

echo "::group::Package"
rm -rf "$DIST"; mkdir -p "$DIST/pkg"
install -m755 "$CARGO_TARGET_DIR/release/codex" "$DIST/pkg/codex"
install -m755 "$CARGO_TARGET_DIR/release/codex-code-mode-host" "$DIST/pkg/codex-code-mode-host"
cp "$SRC/LICENSE" "$SRC/NOTICE" "$ROOT/THIRD_PARTY.md" "$DIST/pkg/"
tar -C "$DIST/pkg" -czf "$DIST/codex-termux-aarch64.tar.gz" codex codex-code-mode-host LICENSE NOTICE THIRD_PARTY.md
cp "$DIST/pkg/codex" "$DIST/pkg/codex-code-mode-host" "$DIST/"
(cd "$DIST" && sha256sum codex-termux-aarch64.tar.gz > codex-termux-aarch64.tar.gz.sha256)

VERSION="$VERSION" TAG="$TAG" UPSTREAM_SHA="$UPSTREAM_SHA" RUSTC_VER="$RUSTC_VER" \
V8_VERSION="$V8_VERSION" V8_TAG="$V8_TAG" V8_SHA256="$RUSTY_V8_ARCHIVE_SHA256" \
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
    "code_mode_engine": f"V8 (rusty_v8 {os.environ['V8_VERSION']}, sandbox)",
    "rusty_v8": {"version": os.environ["V8_VERSION"], "release": os.environ["V8_TAG"],
                 "archive_sha256": os.environ["V8_SHA256"]},
    "patches": {p.name: sha(p) for p in sorted((root / "patches").glob("*.patch"))},
    "binary_sha256": sha(dist / "codex"),
    "host_sha256": sha(dist / "codex-code-mode-host"),
    "tarball_sha256": sha(dist / "codex-termux-aarch64.tar.gz"),
}
(dist / "build-manifest.json").write_text(json.dumps(doc, indent=2) + "\n")
PY
rm -rf "$DIST/pkg"
ls -la "$DIST"
echo "::endgroup::"
echo "build: OK: codex $VERSION"
