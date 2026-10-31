# Cargo environment shared by scripts/build.sh and .github/ci/bionic-build.sh, so that
# `cargo test` in CI reuses the artifacts of the release build instead of recompiling the
# dependency tree. Expects WORK to be set; source it, do not execute it.

# LTO off keeps peak memory low on phones and 4-core CI.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-off}"
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
V8_VERSION="${V8_VERSION:-$(sed -nE 's/^v8 = "=([0-9.]+)"$/\1/p' "$WORK/codex/codex-rs/Cargo.toml" 2>/dev/null || true)}"
V8_BUILD="$(sed -nE 's/.*"rusty_v8_build": *([0-9]+).*/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../versions.json")"
V8_TAG="rusty-v8-v$V8_VERSION-b$V8_BUILD"
V8_DIR="$WORK/rusty_v8/$V8_TAG"
export RUSTY_V8_ARCHIVE="$V8_DIR/librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz"
export RUSTY_V8_SRC_BINDING_PATH="$V8_DIR/src_binding_ptrcomp_sandbox_release_aarch64-linux-android.rs"
RUSTY_V8_ARCHIVE_SHA256="$(awk -v f="${RUSTY_V8_ARCHIVE##*/}" '$2 == f { print $1 }' "$V8_DIR/SHA256SUMS" 2>/dev/null || true)"
export RUSTY_V8_ARCHIVE_SHA256
# The archive needs compiler-rt (__clear_cache) and liblog, which rustc does not link on Android.
CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=$(clang -print-libgcc-file-name) -C link-arg=-llog"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS
