#!/usr/bin/env bash
set -euo pipefail

APP_DEST="/Applications/System Guard.app"
PLIST_DEST="$HOME/Library/LaunchAgents/local.aryan.SystemGuard.plist"
GUI_DOMAIN="gui/$(id -u)"

if [[ -x "$APP_DEST/Contents/MacOS/SystemGuard" ]]; then
  "$APP_DEST/Contents/MacOS/SystemGuard" --unregister-login-item >/dev/null 2>&1 || true
fi

launchctl bootout "$GUI_DOMAIN" "$PLIST_DEST" >/dev/null 2>&1 || true
pkill -f "$APP_DEST/Contents/MacOS/SystemGuard" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"
rm -rf "$APP_DEST"

echo "System Guard removed"
