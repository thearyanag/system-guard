#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT_DIR/build/System Guard.app"
APP_DEST="/Applications/System Guard.app"
PLIST_DEST="$HOME/Library/LaunchAgents/local.aryan.SystemGuard.plist"
GUI_DOMAIN="gui/$(id -u)"

"$ROOT_DIR/scripts/build-app.sh" >/dev/null

mkdir -p "$HOME/Library/Logs/SystemGuard"

if [[ -x "$APP_DEST/Contents/MacOS/SystemGuard" ]]; then
  "$APP_DEST/Contents/MacOS/SystemGuard" --unregister-login-item >/dev/null 2>&1 || true
fi

if pgrep -f "$APP_DEST/Contents/MacOS/SystemGuard" >/dev/null 2>&1; then
  pkill -f "$APP_DEST/Contents/MacOS/SystemGuard" || true
fi

launchctl bootout "$GUI_DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"

rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

if command -v codesign >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/sign-app.sh" "$APP_DEST" >/dev/null
fi

/usr/bin/open -gj "$APP_DEST"

echo "$APP_DEST"
