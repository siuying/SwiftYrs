#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/native/yrs-bridge"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
BUILD_DIR="$ROOT_DIR/.build/xcframework"
HEADERS_DIR="$BUILD_DIR/include"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework"

TARGETS=(
  "aarch64-apple-darwin:macos-arm64"
  "aarch64-apple-ios:ios-arm64"
  "aarch64-apple-ios-sim:ios-simulator-arm64"
)

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

rm -rf "$BUILD_DIR"
mkdir -p "$ARTIFACTS_DIR" "$HEADERS_DIR"
cp "$ROOT_DIR/native/include/YrsBridgeFFI.h" "$HEADERS_DIR/"
cp "$ROOT_DIR/native/include/module.modulemap" "$HEADERS_DIR/"
rm -rf "$XCFRAMEWORK_PATH"

XCFRAMEWORK_ARGS=()
for entry in "${TARGETS[@]}"; do
  rust_target="${entry%%:*}"
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --release --target "$rust_target"
  library_path="$CRATE_DIR/target/$rust_target/release/libyrs_bridge.a"
  XCFRAMEWORK_ARGS+=("-library" "$library_path" "-headers" "$HEADERS_DIR")
done

xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$XCFRAMEWORK_PATH"

echo "Built $XCFRAMEWORK_PATH"
