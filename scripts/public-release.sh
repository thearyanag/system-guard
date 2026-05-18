#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT_DIR/Support/Info.plist"
SOURCE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"

export BUNDLE_ID="${BUNDLE_ID:-$SOURCE_BUNDLE_ID}"
export NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/signing-doctor.sh" public
"$ROOT_DIR/scripts/notarize-release.sh"
"$ROOT_DIR/scripts/release-preflight.sh" public
"$ROOT_DIR/scripts/release-status.sh" --require-public

echo "public release ok"
