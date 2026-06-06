#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/native/yrs-bridge"
ARTIFACTS_DIR="$ROOT_DIR/Artifacts/linux"

mkdir -p "$ARTIFACTS_DIR/include" "$ARTIFACTS_DIR/lib" "$ARTIFACTS_DIR/pkgconfig"

cp "$ROOT_DIR/native/include/YrsBridgeFFI.h" "$ARTIFACTS_DIR/include/"

cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --release

cp "$CRATE_DIR/target/release/libyrs_bridge.a" "$ARTIFACTS_DIR/lib/"

cat > "$ARTIFACTS_DIR/pkgconfig/yrs-bridge.pc" <<EOF
prefix=$ARTIFACTS_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: yrs-bridge
Description: Yrs bridge FFI library
Version: 0.1.0
Libs: -L\${libdir} -lyrs_bridge
Cflags: -I\${includedir}
EOF

echo "Built Linux artifacts at $ARTIFACTS_DIR"
echo ""
echo "Before running 'swift build', set:"
echo "  export PKG_CONFIG_PATH=$ARTIFACTS_DIR/pkgconfig"
