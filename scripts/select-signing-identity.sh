#!/usr/bin/env bash
set -euo pipefail

REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"

resolve_identity() {
  local identity="$1"

  awk -v identity="$identity" '
    $2 == identity {
      if (match($0, /"[^"]+"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        found = 1
        exit
      }
    }
    index($0, "\"" identity "\"") > 0 {
      print identity
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  ' <<<"$IDENTITIES"
}

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  if ! RESOLVED_IDENTITY="$(resolve_identity "$SIGN_IDENTITY")"; then
    echo "signing identity not found in keychain: $SIGN_IDENTITY" >&2
    exit 1
  fi
  if [[ "$REQUIRE_DEVELOPER_ID" == "1" && "$RESOLVED_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "release signing requires a Developer ID Application identity, got: $RESOLVED_IDENTITY" >&2
    exit 1
  fi
  printf '%s\n' "$RESOLVED_IDENTITY"
  exit 0
fi

IDENTITY="$(awk -F '"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")"

if [[ -z "$IDENTITY" && "$REQUIRE_DEVELOPER_ID" != "1" ]]; then
  IDENTITY="$(awk -F '"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")"
fi

if [[ -z "$IDENTITY" && "$REQUIRE_DEVELOPER_ID" != "1" ]]; then
  IDENTITY="$(awk -F '"' '/Mac Developer/ {print $2; exit}' <<<"$IDENTITIES")"
fi

if [[ -n "$IDENTITY" ]]; then
  printf '%s\n' "$IDENTITY"
fi
