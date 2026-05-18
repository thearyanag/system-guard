#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT_DIR/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
DMG_PATH="$ROOT_DIR/dist/SystemGuard-${VERSION}-${BUILD}.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$DMG_PATH.manifest.plist"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"
FAILURES=0
PUBLIC_SIGNING_DOCTOR_FAILED=0
PUBLIC_PREFLIGHT_FAILED=0

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

contains() {
  local label="$1"
  local pattern="$2"
  shift 2
  if rg -q -- "$pattern" "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

developer_id_available() {
  security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {found=1} END {exit !found}'
}

notary_profile_authenticates() {
  xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json --no-progress >/dev/null 2>&1
}

print_public_release_guidance() {
  cat >&2 <<'EOF'
Next public-release command after prerequisites are installed:

  ./scripts/signing-doctor.sh public
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/public-release.sh

Prerequisites:
EOF

  local printed=0
  if ! developer_id_available; then
    echo "- Developer ID Application certificate in the local keychain" >&2
    printed=1
  fi
  if ! notary_profile_authenticates; then
    echo "- authenticating $NOTARYTOOL_PROFILE keychain profile, creatable with ./scripts/setup-notary-profile.sh" >&2
    printed=1
  fi
  if [[ "$printed" == "0" ]]; then
    echo "- inspect the public signing doctor and public preflight failures above" >&2
  fi
}

cd "$ROOT_DIR"

echo "System Guard completion audit"
echo
echo "Objective: launch-ready DMG with safety confirmations, SMAppService login item, smoke/parser coverage, and public signing/notarization gate."
echo

contains "Force Kill confirmation is wired" "Force-kill stale browser automation" Sources/SystemGuard/SystemGuardApp.swift
contains "Quit Docker confirmation is wired" "Quit Docker Desktop\\?" Sources/SystemGuard/SystemGuardApp.swift
contains "destructive actions use modal confirmation" "NSAlert" Sources/SystemGuard/SystemGuardApp.swift
contains "destructive confirmations include Cancel" "Cancel" Sources/SystemGuard/SystemGuardApp.swift
contains "stale confirmation formatter is used by dialog" "StaleProcessConfirmationFormatter\\.lines" Sources/SystemGuard/SystemGuardApp.swift
contains "stale automation prompt lists exact PIDs" "process\\.pid" Sources/SystemGuard/SystemGuardApp.swift
contains "stale automation prompt lists process names" "process\\.shortName" Sources/SystemGuard/SystemGuardApp.swift
contains "stale automation prompt lists memory usage" "process\\.rssGiB" Sources/SystemGuard/SystemGuardApp.swift
contains "stale automation prompt lists process age" "process\\.elapsed" Sources/SystemGuard/SystemGuardApp.swift
contains "stale confirmation detail is self-tested" "stale confirmation process detail line" Sources/SystemGuard/SystemGuardApp.swift
contains "Force Kill uses SIGKILL only after confirmation path" "SIGKILL" Sources/SystemGuard/SystemGuardApp.swift

contains "SMAppService launch-at-login is used" "SMAppService.mainApp" Sources/SystemGuard/SystemGuardApp.swift
contains "legacy LaunchAgent is removed by install/uninstall" "local.aryan.SystemGuard.plist" scripts/install.sh scripts/uninstall.sh scripts/smoke.sh
check "legacy LaunchAgent source is absent" test ! -e launchd/local.aryan.SystemGuard.plist
contains "app-native login item unregister CLI exists" "--unregister-login-item" Sources/SystemGuard/SystemGuardApp.swift scripts/uninstall.sh
contains "app-native login item status CLI exists" "--login-item-status" Sources/SystemGuard/SystemGuardApp.swift scripts/smoke.sh

check "package-release script exists" test -x scripts/package-release.sh
check "public-release script exists" test -x scripts/public-release.sh
check "notarize-release script exists" test -x scripts/notarize-release.sh
check "release preflight script exists" test -x scripts/release-preflight.sh
check "notary profile setup script exists" test -x scripts/setup-notary-profile.sh
check "signing doctor script exists" test -x scripts/signing-doctor.sh
check "release manifest writer exists" test -x scripts/write-release-manifest.sh
check "release status script exists" test -x scripts/release-status.sh
check "completion audit script is executable" test -x scripts/completion-audit.sh
check "DMG lock helper is executable" test -x scripts/dmg-lock.sh

contains "DMG name is versioned from app metadata" "SystemGuard-\\$\\{VERSION\\}-\\$\\{BUILD\\}\\.dmg" scripts/package-release.sh
contains "DMG packaging uses hdiutil" "hdiutil create" scripts/package-release.sh
contains "release checksum is emitted" "shasum -a 256" scripts/package-release.sh scripts/notarize-release.sh
contains "release manifest is emitted" "write-release-manifest\\.sh" scripts/package-release.sh scripts/notarize-release.sh
contains "release manifest records checksum" "checksumAlgorithm|checksum" scripts/write-release-manifest.sh
contains "release manifest records signing state" "appSignedWithDeveloperID|dmgStapled" scripts/write-release-manifest.sh
contains "release manifest records team identifiers" "appTeamIdentifier|dmgTeamIdentifier" scripts/write-release-manifest.sh
contains "release status reports public readiness" "publicReady" scripts/release-status.sh
contains "release status reports local readiness" "localReady" scripts/release-status.sh
contains "release status reports checksum state" "checksumStatus" scripts/release-status.sh
contains "release status can require public artifact" "--require-public" scripts/release-status.sh
contains "DMG contents are mounted and verified" "verify_dmg_contents|mount_dmg" scripts/package-release.sh scripts/release-preflight.sh scripts/notarize-release.sh
contains "DMG mounts are serialized" "dmg-lock.sh" scripts/package-release.sh scripts/release-preflight.sh scripts/notarize-release.sh
contains "codesign verification is part of release checks" "codesign --verify" scripts/package-release.sh scripts/release-preflight.sh scripts/notarize-release.sh scripts/smoke.sh
contains "ad-hoc app fallback keeps hardened runtime" "--options runtime" scripts/sign-app.sh
contains "ad-hoc DMG fallback is signed" "codesign --force --sign -" scripts/package-release.sh
contains "Xcode signing readiness is checked by CLI" "xcodebuild|notarytool|Developer ID Application" scripts/signing-doctor.sh scripts/release-preflight.sh scripts/notarize-release.sh
contains "public release wrapper runs signing doctor first" "signing-doctor\\.sh.*public" scripts/public-release.sh
contains "public release wrapper runs notarization" "notarize-release\\.sh" scripts/public-release.sh
contains "public release wrapper runs public preflight" "release-preflight\\.sh.*public" scripts/public-release.sh
contains "public release wrapper requires public status" "release-status\\.sh.*--require-public" scripts/public-release.sh
contains "notary profile setup stores credentials" "notarytool store-credentials" scripts/setup-notary-profile.sh
contains "notary profile setup verifies credentials" "notarytool history" scripts/setup-notary-profile.sh
contains "snapshot mode is part of release checks" "--snapshot" scripts/package-release.sh scripts/release-preflight.sh scripts/smoke.sh Sources/SystemGuard/SystemGuardApp.swift
contains "login-item status is part of release checks" "--login-item-status" scripts/package-release.sh scripts/release-preflight.sh scripts/smoke.sh Sources/SystemGuard/SystemGuardApp.swift

contains "parser self-test mode exists" "runSelfTests" Sources/SystemGuard/SystemGuardApp.swift
contains "memory_pressure parser is self-tested" "memory_pressure free percentage parse" Sources/SystemGuard/SystemGuardApp.swift
contains "vm_stat parser is self-tested" "vm_stat available percentage fallback" Sources/SystemGuard/SystemGuardApp.swift
contains "ps parser is self-tested" "ps record count" Sources/SystemGuard/SystemGuardApp.swift
contains "elapsed-time parser is self-tested" "elapsed HH:MM:SS parse" Sources/SystemGuard/SystemGuardApp.swift
contains "process classification is self-tested" "headless Chrome classification|node classification" Sources/SystemGuard/SystemGuardApp.swift

check "release manifest exists" test -s "$MANIFEST_PATH"
check "release manifest is valid plist" plutil -lint "$MANIFEST_PATH"
check "release manifest checksum matches checksum file" bash -c '[[ "$(/usr/libexec/PlistBuddy -c "Print :checksum" "$1")" == "$(awk "{print \$1; exit}" "$2")" ]]' _ "$MANIFEST_PATH" "$CHECKSUM_PATH"
check "release manifest bundle id is final" bash -c 'bundle_id="$(/usr/libexec/PlistBuddy -c "Print :bundleIdentifier" "$1")"; [[ "$bundle_id" == *.* && "$bundle_id" != local.* ]]' _ "$MANIFEST_PATH"
check "release manifest team identifiers match" bash -c 'app_team="$(/usr/libexec/PlistBuddy -c "Print :appTeamIdentifier" "$1")"; dmg_team="$(/usr/libexec/PlistBuddy -c "Print :dmgTeamIdentifier" "$1")"; [[ -n "$app_team" && "$app_team" == "$dmg_team" ]]' _ "$MANIFEST_PATH"
check "release status command runs" ./scripts/release-status.sh

contains "smoke supports install mode" "--install" scripts/smoke.sh
contains "smoke builds icon" "build-icon\\.sh" scripts/smoke.sh
contains "smoke builds app" "build-app\\.sh" scripts/smoke.sh
contains "smoke verifies icon exists" "SystemGuard\\.icns" scripts/smoke.sh
contains "smoke verifies codesign" "codesign --verify" scripts/smoke.sh
contains "smoke runs snapshot mode" "--snapshot" scripts/smoke.sh
contains "smoke install mode runs installer" "install\\.sh" scripts/smoke.sh
contains "smoke verifies build bundle identifier" "CFBundleIdentifier" scripts/smoke.sh
contains "smoke install mode verifies installed bundle identifier" "INSTALLED_APP/Contents/Info.plist" scripts/smoke.sh
contains "smoke install mode verifies legacy LaunchAgent absence" "LaunchAgents/local\\.aryan\\.SystemGuard\\.plist" scripts/smoke.sh
check "smoke script passes" ./scripts/smoke.sh
check "smoke install mode passes" ./scripts/smoke.sh --install
check "local signing doctor passes" ./scripts/signing-doctor.sh local

if ./scripts/signing-doctor.sh public; then
  pass "public signing doctor passes"
else
  PUBLIC_SIGNING_DOCTOR_FAILED=1
  fail "public signing doctor passes"
fi

check "local release preflight passes" ./scripts/release-preflight.sh local

if ./scripts/release-preflight.sh public; then
  pass "public release preflight passes"
else
  PUBLIC_PREFLIGHT_FAILED=1
  fail "public release preflight passes"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo
  if [[ "$PUBLIC_SIGNING_DOCTOR_FAILED" == "1" || "$PUBLIC_PREFLIGHT_FAILED" == "1" ]]; then
    print_public_release_guidance
    echo >&2
  fi
  echo "$FAILURES completion audit check(s) failed" >&2
  exit 1
fi

echo
echo "completion audit ok"
