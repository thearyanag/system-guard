#!/usr/bin/env bash
set -euo pipefail

LOCK_DIR="${TMPDIR:-/tmp}/systemguard-dmg.lock"
WAIT_SECONDS="${DMG_LOCK_TIMEOUT_SECONDS:-30}"
STARTED_AT="$(date +%s)"

while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  NOW="$(date +%s)"
  if (( NOW - STARTED_AT >= WAIT_SECONDS )); then
    echo "timed out waiting for DMG lock: $LOCK_DIR" >&2
    exit 1
  fi
  sleep 0.2
done

cleanup() {
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$@"
