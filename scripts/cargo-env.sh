# shellcheck shell=bash
# Cargo environment shared by scripts/build.sh and .github/ci/bionic-build.sh, so that
# `cargo test` in CI reuses the artifacts of the release build instead of recompiling the
# dependency tree. Expects WORK to be set; source it, do not execute it.

# Thin LTO + lld (--gc-sections / --icf=safe) shrinks the Android binaries and RSS while
# keeping CI link memory well within 16 GB. Override with CARGO_PROFILE_RELEASE_LTO=off on
# memory-constrained phones.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-thin}"
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}"
export CARGO_PROFILE_RELEASE_STRIP=true
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/target}"
# protoc-bin-vendored has no Android binary; patch 0001 makes build.rs honor PROTOC.
export PROTOC="${PROTOC:-$(command -v protoc)}"

# Code Mode's V8: rusty_v8 publishes no Android archive, so the v8 crate links the one that
# .github/workflows/rusty-v8.yml builds for the exact version upstream pins (release
# rusty-v8-v<version>-b<rusty_v8_build>), and that build.sh downloads to $WORK/rusty_v8. The
# pinned hash makes the crate's build script check the archive, and run again when it changes.
if [ -z "${V8_VERSION:-}" ] && [ -f "$WORK/codex/codex-rs/Cargo.toml" ]; then
  V8_VERSION="$(python3 - "$WORK/codex/codex-rs/Cargo.toml" 2>/dev/null <<'PY' || true
import re, sys, tomllib
doc = tomllib.load(open(sys.argv[1], "rb"))
spec = doc.get("workspace", {}).get("dependencies", {}).get("v8")
ver = spec if isinstance(spec, str) else spec.get("version", "") if isinstance(spec, dict) else ""
m = re.fullmatch(r"=([0-9]+\.[0-9]+\.[0-9]+)", ver)
if m:
    print(m.group(1))
PY
)"
fi
V8_BUILD="$(sed -nE 's/.*"rusty_v8_build": *([0-9]+).*/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../versions.json")"
V8_TAG="rusty-v8-v$V8_VERSION-b$V8_BUILD"
V8_DIR="$WORK/rusty_v8/$V8_TAG"
export V8_VERSION V8_TAG V8_DIR
export RUSTY_V8_ARCHIVE="$V8_DIR/librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz"
export RUSTY_V8_SRC_BINDING_PATH="$V8_DIR/src_binding_ptrcomp_sandbox_release_aarch64-linux-android.rs"
RUSTY_V8_ARCHIVE_SHA256="$(awk -v f="${RUSTY_V8_ARCHIVE##*/}" '$2 == f { print $1 }' "$V8_DIR/SHA256SUMS" 2>/dev/null || true)"
export RUSTY_V8_ARCHIVE_SHA256
# The archive needs compiler-rt (__clear_cache) and liblog, which rustc does not link on Android.
CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=$(clang -print-libgcc-file-name) -C link-arg=-llog -C link-arg=-Wl,--gc-sections"
if command -v ld.lld >/dev/null 2>&1 || command -v lld >/dev/null 2>&1; then
  CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS -C link-arg=-fuse-ld=lld -C link-arg=-Wl,--icf=safe"
fi
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS
