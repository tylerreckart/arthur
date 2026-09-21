#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
DIST="$ROOT/dist/Arthur.app"
MACOS="$DIST/Contents/MacOS"
RES="$DIST/Contents/Resources"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx26.0"

rm -rf "$DIST"
mkdir -p "$MACOS" "$RES"

swiftc -parse-as-library -O \
  -target "$TARGET" \
  -sdk "$SDK" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework Metal \
  -framework MetalKit \
  -framework QuartzCore \
  -lsqlite3 \
  -o "$MACOS/Arthur" \
  "$SRC"/*.swift

cp "$ROOT/Info.plist" "$DIST/Contents/Info.plist"
if [[ -f "$ROOT/Arthur.entitlements" ]]; then
  codesign --force --sign - --entitlements "$ROOT/Arthur.entitlements" "$DIST"
else
  codesign --force --sign - "$DIST"
fi

echo "built $DIST"
echo "open -a $DIST"
