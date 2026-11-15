#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/FlexbarPower.app}"
OUTPUT_DIR="${2:-$ROOT_DIR/artifacts}"
ZIP_PATH="$OUTPUT_DIR/FlexbarPower-0.1.0-macOS-arm64.zip"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/Scripts/build.sh" "$ROOT_DIR/build"
fi

mkdir -p "$OUTPUT_DIR"
ditto -c -k --keepParent --sequesterRsrc --rsrc "$APP_DIR" "$ZIP_PATH"

printf 'Created %s\n' "$ZIP_PATH"
