#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 VERSION (for example 0.6.0)" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$1"
TAG="v$VERSION"

"$ROOT_DIR/scripts/package-binary-artifact.sh"
CHECKSUM="$(swift package compute-checksum "$ROOT_DIR/Artifacts/YrsBridge.xcframework.zip")"
PACKAGE_FILE="$ROOT_DIR/Package.swift"

perl -0pi -e 's#https://github\.com/siuying/SwiftYrs/releases/download/v[^/]+/YrsBridge\.xcframework\.zip#https://github.com/siuying/SwiftYrs/releases/download/'"$TAG"'/YrsBridge.xcframework.zip#' "$PACKAGE_FILE"
perl -0pi -e 's#checksum: "[^"]+"#checksum: "'"$CHECKSUM"'"#' "$PACKAGE_FILE"

echo "Updated Package.swift for $TAG with checksum $CHECKSUM"
echo "Commit Package.swift, create/push $TAG, then let the tag workflow publish Artifacts/YrsBridge.xcframework.zip."
