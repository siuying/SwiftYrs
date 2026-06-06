#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSUMER_DIR="$ROOT_DIR/Fixtures/BinaryConsumer"

if [[ ! -d "$ROOT_DIR/Artifacts/YrsBridge.xcframework" ]]; then
  "$ROOT_DIR/scripts/build-xcframework.sh"
fi

swift build --package-path "$CONSUMER_DIR"
