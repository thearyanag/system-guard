#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="System Guard"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/dmg-staging"
PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_NAME="SystemGuard-${VERSION}-${BUILD}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_ADHOC="${ALLOW_ADHOC:-1}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"
BUNDLE_ID="${BUNDLE_ID:-}"
MOUNT_POINT=""

is_final_bundle_id() {
  local bundle_id="$1"
  [[ -n "$bundle_id" && "$bundle_id" == *.* && "$bundle_id" != local.* ]]
}

source_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true
}

require_public_bundle_id() {
  if [[ "$REQUIRE_DEVELOPER_ID" != "1" ]]; then
    return
  fi

  if is_final_bundle_id "$BUNDLE_ID" || is_final_bundle_id "$(source_bundle_id)"; then
    return
  fi

    cat >&2 <<'EOF'
Public release packaging requires a final reverse-DNS bundle identifier.

Either update Support/Info.plist or pass:
  BUNDLE_ID=com.example.systemguard SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ALLOW_ADHOC=0 REQUIRE_DEVELOPER_ID=1 ./scripts/package-release.sh
EOF
  exit 1
}

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${SYSTEMGUARD_DMG_LOCK_HELD:-0}" != "1" ]]; then
  exec "$ROOT_DIR/scripts/dmg-lock.sh" env SYSTEMGUARD_DMG_LOCK_HELD=1 "$ROOT_DIR/scripts/package-release.sh" "$@"
fi

verify_app_bundle() {
  local app_bundle="$1"

  test -d "$app_bundle"
  test -x "$app_bundle/Contents/MacOS/SystemGuard"
  test -s "$app_bundle/Contents/Resources/SystemGuard.icns"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_bundle/Contents/Info.plist")" == "SystemGuard.icns" ]]
  codesign --verify --deep --strict --verbose=2 "$app_bundle" >/dev/null
  "$app_bundle/Contents/MacOS/SystemGuard" --self-test >/dev/null
  "$app_bundle/Contents/MacOS/SystemGuard" --snapshot >/dev/null
  "$app_bundle/Contents/MacOS/SystemGuard" --login-item-status >/dev/null
}

verify_final_bundle_id() {
  local app_bundle="$1"
  local bundle_id

  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")"
  if [[ -z "$bundle_id" || "$bundle_id" != *.* || "$bundle_id" == local.* ]]; then
    echo "$app_bundle has non-public bundle identifier: $bundle_id" >&2
    exit 1
  fi
}

verify_dmg_contents() {
  MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/systemguard-dmg.XXXXXX")"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null

  if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    echo "failed to locate mounted DMG volume" >&2
    exit 1
  fi

  test -L "$MOUNT_POINT/Applications"
  verify_app_bundle "$MOUNT_POINT/$APP_NAME.app"
}

cd "$ROOT_DIR"

require_public_bundle_id

SIGN_IDENTITY="$(SIGN_IDENTITY="$SIGN_IDENTITY" REQUIRE_DEVELOPER_ID="$REQUIRE_DEVELOPER_ID" "$ROOT_DIR/scripts/select-signing-identity.sh")"

if [[ "$REQUIRE_DEVELOPER_ID" == "1" && -z "$SIGN_IDENTITY" ]]; then
  echo "release package requires a Developer ID Application identity. Install one or set SIGN_IDENTITY." >&2
  exit 1
fi

if [[ "$REQUIRE_DEVELOPER_ID" == "1" && "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "release package requires a Developer ID Application identity, got: $SIGN_IDENTITY" >&2
  exit 1
fi

export SIGN_IDENTITY
export ALLOW_ADHOC
export REQUIRE_DEVELOPER_ID
export BUNDLE_ID
"$ROOT_DIR/scripts/build-app.sh" >/dev/null
"$ROOT_DIR/scripts/sign-app.sh" "$APP_BUNDLE" >/dev/null
verify_app_bundle "$APP_BUNDLE"

if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
  verify_final_bundle_id "$APP_BUNDLE"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true
fi
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
elif [[ "$ALLOW_ADHOC" == "1" ]]; then
  codesign --force --sign - "$DMG_PATH"
fi

codesign --verify --verbose=2 "$DMG_PATH" >/dev/null
verify_dmg_contents

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" | tee "$(basename "$CHECKSUM_PATH")"
)

"$ROOT_DIR/scripts/write-release-manifest.sh" "$DMG_PATH" "$APP_BUNDLE" "$CHECKSUM_PATH" >/dev/null

echo "$DMG_PATH"
