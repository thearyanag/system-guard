#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_PATH="$ROOT_DIR/dist/SystemGuard-${VERSION}-${BUILD}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$DMG_PATH.manifest.plist"

case "$MODE" in
  ""|--require-public) ;;
  *)
    echo "usage: $0 [--require-public]" >&2
    exit 2
    ;;
esac

manifest_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$MANIFEST_PATH" 2>/dev/null || printf 'missing'
}

bool_value() {
  case "$(manifest_value "$1")" in
    true) printf 'yes' ;;
    false) printf 'no' ;;
    *) printf 'missing' ;;
  esac
}

checksum_file_value() {
  if [[ -s "$CHECKSUM_PATH" ]]; then
    awk '{print $1; exit}' "$CHECKSUM_PATH"
  else
    printf 'missing'
  fi
}

checksum_status() {
  if [[ ! -s "$DMG_PATH" || ! -s "$CHECKSUM_PATH" ]]; then
    printf 'missing'
    return
  fi
  if (cd "$(dirname "$CHECKSUM_PATH")" && shasum -a 256 -c "$(basename "$CHECKSUM_PATH")" >/dev/null 2>&1); then
    printf 'ok'
  else
    printf 'mismatch'
  fi
}

bundle_id_final() {
  local bundle_id
  bundle_id="$(manifest_value bundleIdentifier)"
  [[ "$bundle_id" == *.* && "$bundle_id" != local.* ]]
}

local_ready() {
  [[ "$(checksum_status)" == "ok" ]] &&
  bundle_id_final &&
  [[ "$(manifest_value appHardenedRuntime)" == "true" ]] &&
  [[ "$(manifest_value appHasSecureTimestamp)" == "true" ]] &&
  [[ -s "$DMG_PATH" ]]
}

public_ready() {
  [[ "$(checksum_status)" == "ok" ]] &&
  [[ "$(manifest_value appSignedWithDeveloperID)" == "true" ]] &&
  [[ "$(manifest_value dmgSignedWithDeveloperID)" == "true" ]] &&
  [[ "$(manifest_value dmgStapled)" == "true" ]] &&
  [[ "$(manifest_value appHardenedRuntime)" == "true" ]] &&
  [[ "$(manifest_value appHasSecureTimestamp)" == "true" ]] &&
  [[ "$(manifest_value dmgHasSecureTimestamp)" == "true" ]]
}

if [[ ! -s "$MANIFEST_PATH" ]]; then
  cat <<EOF
System Guard release status
dmg=$DMG_PATH
manifest=missing
checksumFile=$CHECKSUM_PATH
checksumFileValue=$(checksum_file_value)
checksumStatus=$(checksum_status)
localReady=no
publicReady=no
EOF
  if [[ "$MODE" == "--require-public" ]]; then
    exit 1
  fi
  exit 0
fi

cat <<EOF
System Guard release status
dmg=$DMG_PATH
manifest=$MANIFEST_PATH
version=$(manifest_value version)
build=$(manifest_value build)
bundleIdentifier=$(manifest_value bundleIdentifier)
checksum=$(manifest_value checksum)
checksumFileValue=$(checksum_file_value)
checksumStatus=$(checksum_status)
signingIdentity=$(manifest_value signingIdentity)
appSigningAuthority=$(manifest_value appSigningAuthority)
dmgSigningAuthority=$(manifest_value dmgSigningAuthority)
appTeamIdentifier=$(manifest_value appTeamIdentifier)
dmgTeamIdentifier=$(manifest_value dmgTeamIdentifier)
appHardenedRuntime=$(bool_value appHardenedRuntime)
appSecureTimestamp=$(bool_value appHasSecureTimestamp)
dmgSecureTimestamp=$(bool_value dmgHasSecureTimestamp)
appDeveloperID=$(bool_value appSignedWithDeveloperID)
dmgDeveloperID=$(bool_value dmgSignedWithDeveloperID)
dmgStapled=$(bool_value dmgStapled)
notaryProfile=$(manifest_value notaryProfile)
localReady=$(if local_ready; then printf 'yes'; else printf 'no'; fi)
publicReady=$(if public_ready; then printf 'yes'; else printf 'no'; fi)
EOF

if [[ "$MODE" == "--require-public" ]] && ! public_ready; then
  exit 1
fi
