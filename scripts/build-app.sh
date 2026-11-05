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

# macOS keys a "Documents folder" grant to the app's code identity. An ad-hoc
# signature gets a fresh cdhash on every build, so each rebuild looks like a brand
# new app and the system asks for ~/Documents again — the app-side bookmark cannot
# save a grant the OS keeps forgetting. Prefer a stable identity when the login
# keychain has one (Keychain Access › Certificate Assistant › Create a Certificate
# › Code Signing, named "dsh bar dev"), otherwise stay ad-hoc and say so.
ENTITLEMENTS="$ROOT/Resources/DshBar.entitlements"
SIGN_IDENTITY="${DSHBAR_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi

SIGN_ARGS=(--force --identifier dev.dsh.bar)
if [ -f "$ENTITLEMENTS" ]; then
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

if [ -n "$SIGN_IDENTITY" ]; then
  codesign "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
  echo "signed: $SIGN_IDENTITY"
else
  codesign "${SIGN_ARGS[@]}" --sign - "$APP"
  echo "signed: ad-hoc — set DSHBAR_SIGN_IDENTITY or install a Code Signing"
  echo "        certificate to keep the ~/Documents grant across rebuilds"
fi
echo "cdhash: $(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/{print $2}')"

echo "built: $APP"
echo "open \"$APP\""
