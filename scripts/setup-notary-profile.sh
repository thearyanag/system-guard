#!/usr/bin/env bash
set -euo pipefail

PROFILE="${NOTARYTOOL_PROFILE:-system-guard-notary}"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-${APP_STORE_CONNECT_KEY_PATH:-}}"
ASC_KEY_ID="${ASC_KEY_ID:-${APP_STORE_CONNECT_KEY_ID:-}}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-${APP_STORE_CONNECT_ISSUER_ID:-}}"

default_team_id() {
  security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"Developer ID Application: .* (\([[:alnum:]]\{10,\}\))".*/\1/p' |
    head -n 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  ./scripts/setup-notary-profile.sh

optional:
  NOTARYTOOL_PROFILE=system-guard-notary

app-specific password, interactive:
  ./scripts/setup-notary-profile.sh

The helper prompts for Apple ID, defaults Team ID from the installed Developer ID certificate when possible, and lets notarytool prompt for the app-specific password securely.

app-specific password, noninteractive/CI:
  APPLE_ID=you@example.com TEAM_ID=TEAMID APP_PASSWORD=APP_SPECIFIC_PASSWORD ./scripts/setup-notary-profile.sh

App Store Connect API key, noninteractive/CI:
  ASC_KEY_PATH=/path/AuthKey_KEYID.p8 ASC_KEY_ID=KEYID ASC_ISSUER_ID=ISSUER_UUID ./scripts/setup-notary-profile.sh

Omit ASC_ISSUER_ID only for individual API keys. APP_PASSWORD must be an Apple app-specific password and is intended for noninteractive use only.
EOF
}

if [[ -n "$ASC_KEY_PATH$ASC_KEY_ID$ASC_ISSUER_ID" ]]; then
  if [[ -z "$ASC_KEY_PATH" || -z "$ASC_KEY_ID" ]]; then
    usage
    exit 2
  fi

  STORE_ARGS=(
    "$PROFILE"
    --key "$ASC_KEY_PATH"
    --key-id "$ASC_KEY_ID"
  )
  if [[ -n "$ASC_ISSUER_ID" ]]; then
    STORE_ARGS+=(--issuer "$ASC_ISSUER_ID")
  fi
else
  DEFAULT_TEAM_ID="$(default_team_id || true)"
  if [[ -z "$TEAM_ID" && -n "$DEFAULT_TEAM_ID" ]]; then
    TEAM_ID="$DEFAULT_TEAM_ID"
  fi

  if [[ -t 0 ]]; then
    if [[ -z "$APPLE_ID" ]]; then
      read -r -p "Apple ID: " APPLE_ID
    fi
    if [[ -z "$TEAM_ID" ]]; then
      read -r -p "Team ID: " TEAM_ID
    elif [[ -n "$DEFAULT_TEAM_ID" ]]; then
      read -r -p "Team ID [$TEAM_ID]: " TEAM_ID_INPUT
      TEAM_ID="${TEAM_ID_INPUT:-$TEAM_ID}"
    fi
  fi

  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" ]]; then
    usage
    exit 2
  fi

  if [[ ! -t 0 && -z "$APP_PASSWORD" ]]; then
    usage
    exit 2
  fi

  STORE_ARGS=(
    "$PROFILE"
    --apple-id "$APPLE_ID"
    --team-id "$TEAM_ID"
  )
  if [[ -n "$APP_PASSWORD" ]]; then
    STORE_ARGS+=(--password "$APP_PASSWORD")
  fi
fi

xcrun notarytool store-credentials "${STORE_ARGS[@]}"

xcrun notarytool history --keychain-profile "$PROFILE" --output-format json --no-progress >/dev/null

echo "stored and verified notarytool profile: $PROFILE"
