#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework"
ZIP_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework.zip"
CHECKSUM_PATH="$ARTIFACTS_DIR/YrsBridge.xcframework.zip.checksum"

# The pinned upstream yrs commit uses `if let` guards, which are still unstable
# in current Rust toolchains. Enable the feature across the whole dependency
# graph without forking the crate: RUSTC_BOOTSTRAP=1 permits -Z flags on a
# stable compiler, and -Zcrate-attr injects `#![feature(if_let_guard)]` into
# every crate. This degrades to a harmless warning once the feature stabilises.
# Exported so the child build-xcframework.sh (which runs cargo) inherits it.
export RUSTC_BOOTSTRAP=1
export RUSTFLAGS="${RUSTFLAGS:-} -Zcrate-attr=feature(if_let_guard)"

"$ROOT_DIR/scripts/build-xcframework.sh"

rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
(
  cd "$ARTIFACTS_DIR"
  ditto -c -k --sequesterRsrc --keepParent "YrsBridge.xcframework" "YrsBridge.xcframework.zip"
)

swift package compute-checksum "$ZIP_PATH" | tee "$CHECKSUM_PATH"

echo "Packaged $ZIP_PATH"
echo "Wrote checksum to $CHECKSUM_PATH"
