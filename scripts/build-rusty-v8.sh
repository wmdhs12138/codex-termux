#!/usr/bin/env bash
# Build the V8 that Code Mode links: rusty_v8 (the `v8` crate) for aarch64-linux-android, from
# source, with the V8 sandbox that codex-code-mode-runtime enables (`v8_enable_sandbox`).
#
#   RUSTY_V8_VERSION=152.2.0 scripts/build-rusty-v8.sh
#
# rusty_v8 publishes no Android archive and only cross-compiles one from x86_64 Linux, so this
# runs there (CI: .github/workflows/rusty-v8.yml), not on the phone. Needs git, curl, python3,
# rustup, an Android NDK ($ANDROID_NDK_LATEST_HOME or $ANDROID_NDK_HOME) and libclang 21+
# ($LIBCLANG_PATH) for bindgen; uses sccache when it is on PATH. Output in $WORK/out, named like
# rusty_v8's own release assets.
#
# The Android fixups follow termux-packages' deno package (packages/deno/build.sh and
# v8-patches/), which builds the same crate for Termux, and denoland/rusty_v8#2086.
set -Eeuo pipefail
trap 'rc=$?; command -v sccache >/dev/null && sccache --show-stats; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${RUSTY_V8_VERSION:?set RUSTY_V8_VERSION, the v8 = \"=X\" pin in upstream codex-rs/Cargo.toml}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-rusty-v8: bad version '$VERSION'" >&2; exit 1; }
# Termux's minimum Android API level.
ANDROID_API="${ANDROID_API:-24}"
WORK="${WORK:-$ROOT/work/rusty_v8-build}"
TARGET=aarch64-linux-android
SRC="$WORK/rusty_v8"
OUT="$WORK/out"
NDK="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}}"
NDK_REVISION="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties")"
export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-21/lib}"
# Release asset names; scripts/cargo-env.sh reads the same ones.
ARCHIVE="librusty_v8_ptrcomp_sandbox_release_$TARGET.a.gz"
BINDING="src_binding_ptrcomp_sandbox_release_$TARGET.rs"

mkdir -p "$WORK"
echo "::group::Host"
nproc
free -g
df -h "$WORK"
echo "NDK $NDK_REVISION at $NDK"
echo "::endgroup::"

echo "::group::Fetch rusty_v8 v$VERSION"
rm -rf "$SRC"
git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/denoland/rusty_v8.git "$SRC"
cd "$SRC"
# chromium.googlesource.com occasionally drops connections.
for attempt in 1 2 3; do
  git submodule update --init --recursive --depth 1 --jobs 8 && break
  [ "$attempt" = 3 ] && { echo "submodule update failed after $attempt attempts" >&2; exit 1; }
  sleep 30
done
git submodule status --recursive
echo "::endgroup::"

echo "::group::Android fixups"
# chromium_build reads the NDK from //third_party/android_toolchain/ndk, but build.rs looks for
# it in //third_party/android_ndk and otherwise downloads r26c there. Point both at this NDK.
mkdir -p third_party/android_toolchain
ln -sfn "$NDK" third_party/android_toolchain/ndk
ln -sfn "$NDK" third_party/android_ndk
test -x "third_party/android_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/$TARGET$ANDROID_API-clang++"
# config/android/BUILD.gn reads android_ndk_version, which gclient writes into this file in a
# Chromium checkout; rusty_v8 ships it empty (denoland/chromium_build#208).
cat >> build/config/gclient_args.gni <<'EOF'
declare_args() {
  android_ndk_version = ""
}
EOF
# BINDGEN_EXTRA_CLANG_ARGS below is meant for rusty_v8's own bindgen run, not for the ones
# inside V8's GN build.
python3 - build/rust/gni_impl/run_bindgen.py <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "import sys\n"
assert anchor in text, path
text = text.replace(anchor, anchor + 'os.environ.pop("BINDGEN_EXTRA_CLANG_ARGS", None)\n', 1)
open(path, "w").write(text)
PY
for p in "$ROOT"/patches/rusty_v8/*.patch; do
  echo "applying $(basename "$p")"
  patch -p1 --forward --fuzz=0 --no-backup-if-mismatch < "$p"
done
# The host half of the cross build (torque, mksnapshot) links against Chromium's Debian sysroot.
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
echo "::endgroup::"

echo "::group::Toolchains"
RUSTUP_TOOLCHAIN="$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)"
export RUSTUP_TOOLCHAIN
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --target "$TARGET"
rustc --version
if command -v sccache >/dev/null; then
  export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-8G}" SCCACHE_IDLE_TIMEOUT=0
  sccache --start-server
  sccache --zero-stats
fi
echo "::endgroup::"

echo "::group::cargo build (V8_FROM_SOURCE)"
export V8_FROM_SOURCE=1
export BINDGEN_EXTRA_CLANG_ARGS="--target=$TARGET$ANDROID_API --sysroot=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export EXTRA_GN_ARGS="android_ndk_api_level=$ANDROID_API android_ndk_version=\"r${NDK_REVISION%%.*}\""
start=$(date +%s)
cargo build -vv --locked --release --lib --target "$TARGET" --features v8_enable_sandbox
echo "build took $(( ($(date +%s) - start) / 60 )) min"
echo "::endgroup::"

echo "::group::Package"
GN_OUT="target/$TARGET/release/gn_out"
rm -rf "$OUT"
mkdir -p "$OUT"
gzip -9 -c "$GN_OUT/obj/librusty_v8.a" > "$OUT/$ARCHIVE"
cp "$GN_OUT/src_binding.rs" "$OUT/$BINDING"
cp "$GN_OUT/args.gn" "$OUT/args.gn"
cat > "$OUT/BUILD-INFO.txt" <<EOF
rusty_v8 $VERSION ($(git rev-parse HEAD)), codex-termux recipe b$(sed -nE 's/.*"rusty_v8_build": *([0-9]+).*/\1/p' "$ROOT/versions.json")
target $TARGET, Android API $ANDROID_API, NDK $NDK_REVISION
features v8_enable_sandbox (pointer compression, V8 sandbox), use_custom_libcxx
EOF
(cd "$OUT" && sha256sum "$ARCHIVE" "$BINDING" > SHA256SUMS)
ls -la "$OUT"
cat "$OUT/BUILD-INFO.txt" "$OUT/SHA256SUMS" "$OUT/args.gn"
echo "::endgroup::"
