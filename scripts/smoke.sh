#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/System Guard.app"
INSTALLED_APP="/Applications/System Guard.app"
EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/Support/Info.plist")"
RUN_INSTALL=0

if [[ "${1:-}" == "--install" ]]; then
  RUN_INSTALL=1
fi

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build-icon.sh" >/dev/null
test -s "$ROOT_DIR/Support/SystemGuard.icns"

"$ROOT_DIR/scripts/build-app.sh" >/dev/null
test -x "$APP_BUNDLE/Contents/MacOS/SystemGuard"
test -s "$APP_BUNDLE/Contents/Resources/SystemGuard.icns"

/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_BUNDLE/Contents/Info.plist" | grep -qx 'SystemGuard.icns'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" | grep -qx "$EXPECTED_BUNDLE_ID"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
"$APP_BUNDLE/Contents/MacOS/SystemGuard" --self-test >/dev/null
"$APP_BUNDLE/Contents/MacOS/SystemGuard" --snapshot >/dev/null
"$APP_BUNDLE/Contents/MacOS/SystemGuard" --login-item-status >/dev/null

if [[ "$RUN_INSTALL" == "1" ]]; then
  "$ROOT_DIR/scripts/install.sh" >/dev/null
  test -x "$INSTALLED_APP/Contents/MacOS/SystemGuard"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" | grep -qx "$EXPECTED_BUNDLE_ID"
  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP" >/dev/null
  "$INSTALLED_APP/Contents/MacOS/SystemGuard" --login-item-status >/dev/null
  test ! -f "$HOME/Library/LaunchAgents/local.aryan.SystemGuard.plist"
  pgrep -f "$INSTALLED_APP/Contents/MacOS/SystemGuard" >/dev/null
fi

echo "smoke ok"
