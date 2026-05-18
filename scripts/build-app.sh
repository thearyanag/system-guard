#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/System Guard.app"
EXECUTABLE="$ROOT_DIR/.build/manual-release/SystemGuard"
SDK_PATH="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
ICON_PATH="$ROOT_DIR/Support/SystemGuard.icns"
BUNDLE_ID="${BUNDLE_ID:-}"

if [[ -n "$BUNDLE_ID" && ( "$BUNDLE_ID" != *.* || "$BUNDLE_ID" == local.* ) ]]; then
  echo "BUNDLE_ID must be a final reverse-DNS identifier, got: $BUNDLE_ID" >&2
  exit 1
fi

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/build-icon.sh" >/dev/null
mkdir -p "$ROOT_DIR/.build/manual-release" "$ROOT_DIR/.build/ModuleCache"
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" "$SWIFTC" \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK_PATH" \
  "$ROOT_DIR/Sources/SystemGuard/SystemGuardApp.swift" \
  -o "$EXECUTABLE"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -n "$BUNDLE_ID" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
fi
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/SystemGuard.icns"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/SystemGuard"
chmod +x "$APP_DIR/Contents/MacOS/SystemGuard"

if command -v codesign >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/sign-app.sh" "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
