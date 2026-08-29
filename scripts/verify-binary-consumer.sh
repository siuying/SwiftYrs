#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSUMER_DIR="$ROOT_DIR/Fixtures/BinaryConsumer"

rm -rf "$CONSUMER_DIR/.build"
swift build --package-path "$CONSUMER_DIR"
