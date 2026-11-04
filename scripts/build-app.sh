#!/bin/bash
# Builds `build/dsh bar.app` from the Swift package. No Xcode project required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product DshBar
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/dsh bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/DshBar" "$APP/Contents/MacOS/DshBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

mkdir -p "$ROOT/build/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/build" >/dev/null
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
echo "open \"$APP\""
