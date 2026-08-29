#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSUMER_DIR="$ROOT_DIR/Fixtures/BinaryConsumer"

if [[ -d "$ROOT_DIR/Artifacts/YrsBridge.xcframework" ]]; then
  echo "Refusing to verify a local artifact consumer; remove Artifacts/YrsBridge.xcframework first." >&2
  exit 1
fi

rm -rf "$CONSUMER_DIR/.build"
swift build --package-path "$CONSUMER_DIR"
