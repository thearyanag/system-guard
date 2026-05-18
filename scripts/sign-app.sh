#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app-bundle>" >&2
  exit 2
fi

APP_BUNDLE="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT_DIR/Support/SystemGuard.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_ADHOC="${ALLOW_ADHOC:-1}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"

SIGN_IDENTITY="$(SIGN_IDENTITY="$SIGN_IDENTITY" REQUIRE_DEVELOPER_ID="$REQUIRE_DEVELOPER_ID" "$ROOT_DIR/scripts/select-signing-identity.sh")"

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"
  echo "signed $APP_BUNDLE with identity: $SIGN_IDENTITY"
elif [[ "$ALLOW_ADHOC" == "1" ]]; then
  codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - \
    "$APP_BUNDLE" >/dev/null
  echo "ad-hoc signed $APP_BUNDLE with hardened runtime"
elif [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
  echo "no Developer ID Application identity found. Install one or set SIGN_IDENTITY." >&2
  exit 1
else
  echo "no valid codesigning identity found. Set SIGN_IDENTITY or install an Apple signing certificate." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
