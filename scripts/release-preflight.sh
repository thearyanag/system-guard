#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-local}"
APP_NAME="System Guard"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_PATH="$ROOT_DIR/dist/SystemGuard-${VERSION}-${BUILD}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$DMG_PATH.manifest.plist"
FAILURES=0
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

case "$MODE" in
  local|public) ;;
  *)
    echo "usage: $0 [local|public]" >&2
    exit 2
    ;;
esac

if [[ "${SYSTEMGUARD_DMG_LOCK_HELD:-0}" != "1" ]]; then
  exec "$ROOT_DIR/scripts/dmg-lock.sh" env SYSTEMGUARD_DMG_LOCK_HELD=1 "$ROOT_DIR/scripts/release-preflight.sh" "$@"
fi

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'fail - %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

check_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if grep -q "$needle" <<<"$haystack"; then
    pass "$label"
  else
    fail "$label"
  fi
}

check_final_bundle_id() {
  local label="$1"
  local plist_path="$2"
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null || true)"

  if [[ -n "$bundle_id" && "$bundle_id" != local.* && "$bundle_id" == *.* ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

mount_dmg() {
  MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/systemguard-dmg.XXXXXX")"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]
}

developer_id_identity() {
  SIGN_IDENTITY="${SIGN_IDENTITY:-}" REQUIRE_DEVELOPER_ID=1 "$ROOT_DIR/scripts/select-signing-identity.sh" 2>/dev/null || true
}

cd "$ROOT_DIR"

echo "System Guard release preflight ($MODE)"
echo "version=$VERSION build=$BUILD"

check "script syntax: sign-app" bash -n "$ROOT_DIR/scripts/sign-app.sh"
check "script syntax: package-release" bash -n "$ROOT_DIR/scripts/package-release.sh"
check "script syntax: notarize-release" bash -n "$ROOT_DIR/scripts/notarize-release.sh"
check "script syntax: select-signing-identity" bash -n "$ROOT_DIR/scripts/select-signing-identity.sh"
check "script syntax: signing-doctor" bash -n "$ROOT_DIR/scripts/signing-doctor.sh"
check "script syntax: dmg-lock" bash -n "$ROOT_DIR/scripts/dmg-lock.sh"
check "script syntax: smoke" bash -n "$ROOT_DIR/scripts/smoke.sh"
check "icon source exists" test -s "$ROOT_DIR/Support/SystemGuard.icns"
check "entitlements exist" test -s "$ROOT_DIR/Support/SystemGuard.entitlements"
check "bundle icon key" bash -c "[[ \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST")\" == 'SystemGuard.icns' ]]"
check "DMG exists" test -s "$DMG_PATH"
check "DMG checksum file exists" test -s "$CHECKSUM_PATH"
check "DMG checksum verifies" bash -c 'cd "$1" && shasum -a 256 -c "$2"' _ "$(dirname "$CHECKSUM_PATH")" "$(basename "$CHECKSUM_PATH")"
check "DMG manifest exists" test -s "$MANIFEST_PATH"
check "DMG manifest is valid plist" plutil -lint "$MANIFEST_PATH"
check "DMG manifest checksum matches checksum file" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :checksum" "$1")" == "$(awk "{print \$1; exit}" "$2")" ]]' _ "$MANIFEST_PATH" "$CHECKSUM_PATH"
check "DMG manifest bundle id is final" bash -c 'bundle_id="$(/usr/libexec/PlistBuddy -c "Print :bundleIdentifier" "$1")"; [[ "$bundle_id" == *.* && "$bundle_id" != local.* ]]' _ "$MANIFEST_PATH"
check "DMG manifest team identifiers match" bash -c 'app_team="$(/usr/libexec/PlistBuddy -c "Print :appTeamIdentifier" "$1")"; dmg_team="$(/usr/libexec/PlistBuddy -c "Print :dmgTeamIdentifier" "$1")"; [[ -n "$app_team" && "$app_team" == "$dmg_team" ]]' _ "$MANIFEST_PATH"
check "DMG signature verifies" codesign --verify --verbose=2 "$DMG_PATH"

if [[ -s "$DMG_PATH" ]] && mount_dmg >/dev/null 2>&1; then
  pass "DMG mounts read-only"
  check "mounted app exists" test -d "$MOUNT_POINT/$APP_NAME.app"
  check "mounted Applications symlink exists" test -L "$MOUNT_POINT/Applications"
  check "mounted app icon key" bash -c "[[ \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist")\" == 'SystemGuard.icns' ]]"
  check "mounted app icon exists" test -s "$MOUNT_POINT/$APP_NAME.app/Contents/Resources/SystemGuard.icns"
  check "mounted app executable exists" test -x "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/SystemGuard"
  check "mounted app signature verifies" codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$APP_NAME.app"
  check "mounted app self-test runs" "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/SystemGuard" --self-test
  check "mounted app snapshot runs" "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/SystemGuard" --snapshot
  check "mounted app login-item status runs" "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/SystemGuard" --login-item-status
else
  fail "DMG mounts read-only"
fi

if [[ -d "$APP_BUNDLE" ]]; then
  check "build app signature verifies" codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  check "build app self-test runs" "$APP_BUNDLE/Contents/MacOS/SystemGuard" --self-test
  check "build app snapshot runs" "$APP_BUNDLE/Contents/MacOS/SystemGuard" --snapshot
  check "build app login-item status runs" "$APP_BUNDLE/Contents/MacOS/SystemGuard" --login-item-status
else
  fail "build app exists"
fi

if [[ -d "$INSTALLED_APP" ]]; then
  check "installed app signature verifies" codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
  check "installed app login-item status runs" "$INSTALLED_APP/Contents/MacOS/SystemGuard" --login-item-status
  check "legacy LaunchAgent absent" test ! -f "$HOME/Library/LaunchAgents/local.aryan.SystemGuard.plist"
else
  fail "installed app exists"
fi

if [[ "$MODE" == "public" ]]; then
  if [[ -d "$APP_BUNDLE" ]]; then
    check_final_bundle_id "build app bundle identifier is final" "$APP_BUNDLE/Contents/Info.plist"
  fi

  if [[ -d "$INSTALLED_APP" ]]; then
    check_final_bundle_id "installed app bundle identifier is final" "$INSTALLED_APP/Contents/Info.plist"
  fi

  DEVELOPER_ID="$(developer_id_identity || true)"
  if [[ -n "$DEVELOPER_ID" ]]; then
    pass "Developer ID Application identity available"
  else
    fail "Developer ID Application identity available"
  fi

  NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"
  pass "NOTARYTOOL_PROFILE selected"
  check "NOTARYTOOL_PROFILE authenticates" xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json --no-progress

  if [[ -s "$DMG_PATH" ]]; then
    DMG_SIGNATURE="$(codesign -dv --verbose=4 "$DMG_PATH" 2>&1 || true)"
    check_contains "DMG signed with Developer ID Application" "$DMG_SIGNATURE" "Authority=Developer ID Application"
    check_contains "DMG has secure timestamp" "$DMG_SIGNATURE" "Timestamp="
    check "DMG has stapled notarization ticket" xcrun stapler validate "$DMG_PATH"
    check "DMG passes Gatekeeper" spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
    check "DMG manifest records Developer ID app signature" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :appSignedWithDeveloperID" "$1")" == "true" ]]' _ "$MANIFEST_PATH"
    check "DMG manifest records Developer ID DMG signature" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :dmgSignedWithDeveloperID" "$1")" == "true" ]]' _ "$MANIFEST_PATH"
    check "DMG manifest records stapled ticket" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :dmgStapled" "$1")" == "true" ]]' _ "$MANIFEST_PATH"
    check "DMG manifest records real team identifier" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :appTeamIdentifier" "$1")" != "unknown" ]]' _ "$MANIFEST_PATH"
  fi

  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT/$APP_NAME.app" ]]; then
    check_final_bundle_id "mounted app bundle identifier is final" "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist"
    MOUNTED_APP_SIGNATURE="$(codesign -dv --verbose=4 "$MOUNT_POINT/$APP_NAME.app" 2>&1 || true)"
    check_contains "mounted app signed with Developer ID Application" "$MOUNTED_APP_SIGNATURE" "Authority=Developer ID Application"
    check_contains "mounted app hardened runtime" "$MOUNTED_APP_SIGNATURE" "flags=.*runtime"
    check "mounted app passes Gatekeeper" spctl --assess --type execute -vv "$MOUNT_POINT/$APP_NAME.app"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES preflight check(s) failed" >&2
  exit 1
fi

echo "preflight ok"
