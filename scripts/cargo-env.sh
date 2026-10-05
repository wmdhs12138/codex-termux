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
# rquickjs-sys generates its Android bindings with bindgen, which needs libclang.
export LIBCLANG_PATH="${LIBCLANG_PATH:-$PREFIX/lib}"
