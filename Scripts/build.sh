#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/build}"
APP_DIR="$OUTPUT_DIR/FlexbarPower.app"
CONTENTS_DIR="$APP_DIR/Contents"

mkdir -p \
  "$CONTENTS_DIR/MacOS" \
  "$CONTENTS_DIR/Resources" \
  "$CONTENTS_DIR/Library/LaunchServices" \
  "$CONTENTS_DIR/Library/LaunchDaemons" \
  "$OUTPUT_DIR/swift-module-cache"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/FlexbarPower.icns" "$CONTENTS_DIR/Resources/FlexbarPower.icns"
cp "$ROOT_DIR/Resources/local.flexbar.power.helper.plist" \
  "$CONTENTS_DIR/Library/LaunchDaemons/local.flexbar.power.helper.plist"

swiftc -parse-as-library \
  -module-cache-path "$OUTPUT_DIR/swift-module-cache" \
  -o "$CONTENTS_DIR/MacOS/FlexbarPower" \
  "$ROOT_DIR/Sources/FlexbarPower.swift"

swiftc -module-cache-path "$OUTPUT_DIR/swift-module-cache" \
  -o "$CONTENTS_DIR/Library/LaunchServices/FlexbarPowerHelper" \
  "$ROOT_DIR/Sources/FlexbarPowerHelper.swift"

chmod 755 "$CONTENTS_DIR/MacOS/FlexbarPower" \
  "$CONTENTS_DIR/Library/LaunchServices/FlexbarPowerHelper"
codesign --force --deep --sign - "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"
