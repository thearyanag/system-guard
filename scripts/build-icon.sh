#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PNG="$ROOT_DIR/Support/Assets/SystemGuardIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/iconset/SystemGuard.iconset"
OUTPUT_ICNS="$ROOT_DIR/Support/SystemGuard.icns"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "missing icon source: $SOURCE_PNG" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"

mkdir -p "$ROOT_DIR/.build/ModuleCache"

CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" /usr/bin/swift \
  "$ROOT_DIR/scripts/make-iconset.swift" \
  "$SOURCE_PNG" \
  "$ICONSET_DIR"

CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" /usr/bin/swift \
  "$ROOT_DIR/scripts/make-icns.swift" \
  "$ICONSET_DIR" \
  "$OUTPUT_ICNS"

echo "$OUTPUT_ICNS"
