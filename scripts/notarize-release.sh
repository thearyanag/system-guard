#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="System Guard"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_PATH="$ROOT_DIR/dist/SystemGuard-${VERSION}-${BUILD}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"
BUNDLE_ID="${BUNDLE_ID:-}"
MOUNT_POINT=""

detach_mount() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
}

cleanup() {
  detach_mount
}
trap cleanup EXIT

if [[ "${SYSTEMGUARD_DMG_LOCK_HELD:-0}" != "1" ]]; then
  exec "$ROOT_DIR/scripts/dmg-lock.sh" env SYSTEMGUARD_DMG_LOCK_HELD=1 "$ROOT_DIR/scripts/notarize-release.sh" "$@"
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_developer_id_signature() {
  local target="$1"
  local details
  details="$(codesign -dv --verbose=4 "$target" 2>&1)"

  if ! grep -q "Authority=Developer ID Application" <<<"$details"; then
    echo "$target is not signed with a Developer ID Application identity" >&2
    exit 1
  fi

  if ! grep -q "Timestamp=" <<<"$details"; then
    echo "$target is missing a secure timestamp" >&2
    exit 1
  fi
}

require_hardened_runtime() {
  local target="$1"
  local details
  details="$(codesign -dv --verbose=4 "$target" 2>&1)"

  if ! grep -Eq "flags=.*runtime" <<<"$details"; then
    echo "$target is missing hardened runtime" >&2
    exit 1
  fi
}

require_final_bundle_id() {
  local target="$1"
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")"

  if [[ -z "$bundle_id" || "$bundle_id" != *.* || "$bundle_id" == local.* ]]; then
    echo "$target has non-public bundle identifier: $bundle_id" >&2
    echo "Set BUNDLE_ID=com.aryan.systemguard or update Support/Info.plist." >&2
    exit 1
  fi
}

is_final_bundle_id() {
  local bundle_id="$1"
  [[ -n "$bundle_id" && "$bundle_id" == *.* && "$bundle_id" != local.* ]]
}

source_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/Support/Info.plist" 2>/dev/null || true
}

require_public_bundle_id() {
  if is_final_bundle_id "$BUNDLE_ID" || is_final_bundle_id "$(source_bundle_id)"; then
    return
  fi

    cat >&2 <<'EOF'
Notarized release requires a final reverse-DNS bundle identifier.

Either update Support/Info.plist or pass:
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize-release.sh
EOF
  exit 1
}

require_notary_profile_auth() {
  if ! xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json --no-progress >/dev/null; then
    echo "NOTARYTOOL_PROFILE did not authenticate: $NOTARYTOOL_PROFILE" >&2
    exit 1
  fi
}

mount_dmg() {
  MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/systemguard-dmg.XXXXXX")"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null

  if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
    echo "failed to locate mounted DMG volume" >&2
    exit 1
  fi
}

verify_mounted_app() {
  local mounted_app="$MOUNT_POINT/$APP_NAME.app"

  if [[ ! -d "$mounted_app" ]]; then
    echo "mounted DMG is missing $APP_NAME.app" >&2
    exit 1
  fi

  if [[ ! -L "$MOUNT_POINT/Applications" ]]; then
    echo "mounted DMG is missing Applications symlink" >&2
    exit 1
  fi

  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$mounted_app/Contents/Info.plist")" != "SystemGuard.icns" ]]; then
    echo "mounted app has unexpected CFBundleIconFile" >&2
    exit 1
  fi

  test -s "$mounted_app/Contents/Resources/SystemGuard.icns"
  test -x "$mounted_app/Contents/MacOS/SystemGuard"
  codesign --verify --deep --strict --verbose=2 "$mounted_app" >/dev/null
  require_developer_id_signature "$mounted_app"
  require_hardened_runtime "$mounted_app"
  require_final_bundle_id "$mounted_app"
  "$mounted_app/Contents/MacOS/SystemGuard" --self-test >/dev/null
  "$mounted_app/Contents/MacOS/SystemGuard" --snapshot >/dev/null
}

require_command codesign
require_command hdiutil
require_command shasum
require_command spctl
require_command xcrun

require_public_bundle_id

SIGN_IDENTITY="$(SIGN_IDENTITY="$SIGN_IDENTITY" REQUIRE_DEVELOPER_ID=1 "$ROOT_DIR/scripts/select-signing-identity.sh")"

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "no Developer ID Application identity found. Install one or set SIGN_IDENTITY." >&2
  exit 1
fi

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "notarized release requires a Developer ID Application identity, got: $SIGN_IDENTITY" >&2
  exit 1
fi

require_notary_profile_auth

cd "$ROOT_DIR"

SIGN_IDENTITY="$SIGN_IDENTITY" BUNDLE_ID="$BUNDLE_ID" ALLOW_ADHOC=0 REQUIRE_DEVELOPER_ID=1 "$ROOT_DIR/scripts/package-release.sh" >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null
codesign --verify --verbose=2 "$DMG_PATH" >/dev/null
require_developer_id_signature "$APP_BUNDLE"
require_developer_id_signature "$DMG_PATH"
require_hardened_runtime "$APP_BUNDLE"
require_final_bundle_id "$APP_BUNDLE"

mount_dmg
verify_mounted_app
detach_mount

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

mount_dmg
verify_mounted_app
spctl --assess --type execute -vv "$MOUNT_POINT/$APP_NAME.app"

(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")" | tee "$(basename "$CHECKSUM_PATH")"
)
"$ROOT_DIR/scripts/write-release-manifest.sh" "$DMG_PATH" "$APP_BUNDLE" "$CHECKSUM_PATH" >/dev/null
echo "$DMG_PATH"
