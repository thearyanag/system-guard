#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-public}"
APP_NAME="System Guard"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
PLIST="$ROOT_DIR/Support/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
BUNDLE_ID="${BUNDLE_ID:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"
FAILURES=0

case "$MODE" in
  local|public) ;;
  *)
    echo "usage: $0 [local|public]" >&2
    exit 2
    ;;
esac

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'fail - %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

info() {
  printf 'info - %s\n' "$1"
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

is_final_bundle_id() {
  local bundle_id="$1"
  [[ -n "$bundle_id" && "$bundle_id" == *.* && "$bundle_id" != local.* ]]
}

source_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true
}

current_release_bundle_id() {
  if [[ -n "$BUNDLE_ID" ]]; then
    printf '%s\n' "$BUNDLE_ID"
  else
    source_bundle_id
  fi
}

print_xcode_details() {
  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"

  if [[ -n "$developer_dir" ]]; then
    info "xcode-select: $developer_dir"
  fi

  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version 2>/dev/null | while IFS= read -r line; do
      info "$line"
    done
  fi
}

developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}'
}

selected_identity() {
  SIGN_IDENTITY="$SIGN_IDENTITY" REQUIRE_DEVELOPER_ID="$([[ "$MODE" == "public" ]] && printf 1 || printf 0)" "$ROOT_DIR/scripts/select-signing-identity.sh"
}

describe_app_signature() {
  local app_bundle="$1"
  local details

  if [[ ! -d "$app_bundle" ]]; then
    info "build app not present: $app_bundle"
    return
  fi

  if codesign --verify --deep --strict --verbose=2 "$app_bundle" >/dev/null 2>&1; then
    pass "build app signature verifies"
  else
    fail "build app signature verifies"
    return
  fi

  details="$(codesign -dv --verbose=4 "$app_bundle" 2>&1 || true)"
  if grep -q "Authority=Developer ID Application" <<<"$details"; then
    pass "build app currently signed with Developer ID Application"
  else
    info "build app is not currently Developer ID signed"
  fi

  if grep -Eq "flags=.*runtime" <<<"$details"; then
    pass "build app has hardened runtime"
  else
    fail "build app has hardened runtime"
  fi

  if grep -q "Timestamp=" <<<"$details"; then
    pass "build app has secure timestamp"
  else
    info "build app has no secure timestamp"
  fi
}

echo "System Guard signing doctor ($MODE)"

check "xcode-select is configured" xcode-select -p
check "xcodebuild is available" xcodebuild -version
check "codesign is available" command -v codesign
check "xcrun notarytool is available" xcrun notarytool --help
check "security codesigning lookup works" security find-identity -v -p codesigning
print_xcode_details

if SELECTED_IDENTITY="$(selected_identity 2>/dev/null)"; then
  if [[ -n "$SELECTED_IDENTITY" ]]; then
    pass "selected signing identity: $SELECTED_IDENTITY"
  elif [[ "$MODE" == "local" ]]; then
    info "no signing identity selected; local packaging can fall back to ad-hoc signing"
  else
    fail "selected Developer ID signing identity"
  fi
else
  fail "selected signing identity is valid"
fi

if [[ "$MODE" == "public" ]]; then
  RELEASE_BUNDLE_ID="$(current_release_bundle_id)"
  if is_final_bundle_id "$RELEASE_BUNDLE_ID"; then
    pass "release bundle identifier is final: $RELEASE_BUNDLE_ID"
  else
    fail "release bundle identifier is final"
  fi

  if DEVELOPER_ID="$(developer_id_identity)" && [[ -n "$DEVELOPER_ID" ]]; then
    pass "Developer ID Application identity available: $DEVELOPER_ID"
  else
    fail "Developer ID Application identity available"
  fi

  pass "NOTARYTOOL_PROFILE selected: $NOTARYTOOL_PROFILE"
  check "NOTARYTOOL_PROFILE authenticates" xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json --no-progress
else
  SOURCE_BUNDLE_ID="$(source_bundle_id)"
  info "source bundle identifier: $SOURCE_BUNDLE_ID"
fi

describe_app_signature "$APP_BUNDLE"

if [[ "$FAILURES" -gt 0 ]]; then
  echo "$FAILURES signing doctor check(s) failed" >&2
  exit 1
fi

echo "signing doctor ok"
