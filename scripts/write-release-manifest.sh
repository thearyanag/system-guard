#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <dmg-path> <app-bundle> [checksum-path]" >&2
  exit 2
fi

DMG_PATH="$1"
APP_BUNDLE="$2"
CHECKSUM_PATH="${3:-$DMG_PATH.sha256}"
MANIFEST_PATH="$DMG_PATH.manifest.plist"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

if [[ ! -s "$DMG_PATH" ]]; then
  echo "missing DMG: $DMG_PATH" >&2
  exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -s "$CHECKSUM_PATH" ]]; then
  echo "missing checksum file: $CHECKSUM_PATH" >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

signature_details() {
  codesign -dv --verbose=4 "$1" 2>&1 || true
}

first_authority() {
  awk -F= '/Authority=/ {print $2; exit}' <<<"$1"
}

team_identifier() {
  awk -F= '/TeamIdentifier=/ {print $2; exit}' <<<"$1"
}

has_line() {
  local text="$1"
  local pattern="$2"
  grep -Eq "$pattern" <<<"$text"
}

plist_add_string() {
  /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$MANIFEST_PATH"
}

plist_add_bool() {
  /usr/libexec/PlistBuddy -c "Add :$1 bool $2" "$MANIFEST_PATH"
}

APP_SIGNATURE="$(signature_details "$APP_BUNDLE")"
DMG_SIGNATURE="$(signature_details "$DMG_PATH")"
APP_AUTHORITY="$(first_authority "$APP_SIGNATURE")"
DMG_AUTHORITY="$(first_authority "$DMG_SIGNATURE")"
APP_TEAM_IDENTIFIER="$(team_identifier "$APP_SIGNATURE")"
DMG_TEAM_IDENTIFIER="$(team_identifier "$DMG_SIGNATURE")"
CHECKSUM="$(awk '{print $1; exit}' "$CHECKSUM_PATH")"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SIGNING_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$APP_AUTHORITY"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="ad-hoc"
fi
if [[ -z "$APP_AUTHORITY" ]]; then
  APP_AUTHORITY="unknown"
fi
if [[ -z "$DMG_AUTHORITY" ]]; then
  DMG_AUTHORITY="unknown"
fi
if [[ -z "$APP_TEAM_IDENTIFIER" ]]; then
  APP_TEAM_IDENTIFIER="unknown"
fi
if [[ -z "$DMG_TEAM_IDENTIFIER" ]]; then
  DMG_TEAM_IDENTIFIER="unknown"
fi

REQUIRE_DEVELOPER_ID_BOOL=false
APP_SIGNED_WITH_DEVELOPER_ID=false
APP_HARDENED_RUNTIME=false
APP_HAS_SECURE_TIMESTAMP=false
DMG_SIGNED_WITH_DEVELOPER_ID=false
DMG_HAS_SECURE_TIMESTAMP=false
DMG_STAPLED=false

if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  REQUIRE_DEVELOPER_ID_BOOL=true
fi
if has_line "$APP_SIGNATURE" "Authority=Developer ID Application"; then
  APP_SIGNED_WITH_DEVELOPER_ID=true
fi
if has_line "$APP_SIGNATURE" "flags=.*runtime"; then
  APP_HARDENED_RUNTIME=true
fi
if has_line "$APP_SIGNATURE" "Timestamp="; then
  APP_HAS_SECURE_TIMESTAMP=true
fi
if has_line "$DMG_SIGNATURE" "Authority=Developer ID Application"; then
  DMG_SIGNED_WITH_DEVELOPER_ID=true
fi
if has_line "$DMG_SIGNATURE" "Timestamp="; then
  DMG_HAS_SECURE_TIMESTAMP=true
fi
if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
  DMG_STAPLED=true
fi

cat > "$MANIFEST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF

plist_add_string generatedAt "$GENERATED_AT"
plist_add_string appName "$(plist_value CFBundleName)"
plist_add_string version "$(plist_value CFBundleShortVersionString)"
plist_add_string build "$(plist_value CFBundleVersion)"
plist_add_string bundleIdentifier "$(plist_value CFBundleIdentifier)"
plist_add_string dmgName "$(basename "$DMG_PATH")"
plist_add_string checksumAlgorithm "sha256"
plist_add_string checksum "$CHECKSUM"
plist_add_string signingIdentity "$SIGNING_IDENTITY"
plist_add_string appSigningAuthority "$APP_AUTHORITY"
plist_add_string dmgSigningAuthority "$DMG_AUTHORITY"
plist_add_string appTeamIdentifier "$APP_TEAM_IDENTIFIER"
plist_add_string dmgTeamIdentifier "$DMG_TEAM_IDENTIFIER"
plist_add_string notaryProfile "${NOTARYTOOL_PROFILE:-system-guard-notary}"
plist_add_bool requireDeveloperID "$REQUIRE_DEVELOPER_ID_BOOL"
plist_add_bool appSignedWithDeveloperID "$APP_SIGNED_WITH_DEVELOPER_ID"
plist_add_bool appHardenedRuntime "$APP_HARDENED_RUNTIME"
plist_add_bool appHasSecureTimestamp "$APP_HAS_SECURE_TIMESTAMP"
plist_add_bool dmgSignedWithDeveloperID "$DMG_SIGNED_WITH_DEVELOPER_ID"
plist_add_bool dmgHasSecureTimestamp "$DMG_HAS_SECURE_TIMESTAMP"
plist_add_bool dmgStapled "$DMG_STAPLED"

plutil -lint "$MANIFEST_PATH" >/dev/null
echo "$MANIFEST_PATH"
