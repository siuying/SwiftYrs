#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework"
ZIP_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework.zip"
CHECKSUM_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework.zip.checksum"

"$ROOT_DIR/scripts/build-xcframework.sh"

rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
(
  cd "$ARTIFACTS_DIR"
  ditto -c -k --sequesterRsrc --keepParent "YrsBridge.xcframework" "YrsBridge.xcframework.zip"
)

swift package compute-checksum "$ZIP_PATH" | tee "$CHECKSUM_PATH"

echo "Packaged $ZIP_PATH"
echo "Wrote checksum to $CHECKSUM_PATH"
