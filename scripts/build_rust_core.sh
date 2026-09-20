#!/bin/bash
# build_rust_core.sh
# Compiles rust-core into libairlift_ffi.a (arm64 iOS) for linking into the tweak dylib.
set -euo pipefail

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

# Make ~/.cargo visible to non-login shells (CI)
# shellcheck disable=SC1090
source "$HOME/.cargo/env" 2>/dev/null || true

# Remap $HOME so absolute source paths don't appear in the binary's log output
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/rust-core"

echo "==> Installing aarch64-apple-ios target (if needed)"
rustup target add aarch64-apple-ios 2>/dev/null || true

echo "==> Building airlift_ffi static lib (release, arm64-ios)"
cargo build --release --target aarch64-apple-ios

LIB="$ROOT/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a"
echo "==> Done: $LIB"
ls -lh "$LIB"