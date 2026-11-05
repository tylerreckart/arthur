#!/usr/bin/env bash
# Builds the Xcode project and leaves Arthur.app in dist/, ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

xcodebuild \
  -project "$ROOT/Arthur.xcodeproj" \
  -scheme Arthur \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build" \
  CONFIGURATION_BUILD_DIR="$ROOT/dist" \
  build

echo "built $ROOT/dist/Arthur.app"
echo "open $ROOT/dist/Arthur.app"
