#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${APP_PATH:-/Applications/GroqDictate.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/GroqDictate"
BUILD_EXECUTABLE="$ROOT_DIR/.build/release/GroqDictate"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
LAUNCH_AFTER_BUILD="${LAUNCH_AFTER_BUILD:-1}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_command swift
require_command pkill
require_command open

[[ -d "$APP_PATH" ]] || fail "App bundle not found at: $APP_PATH"

log "→ Building release binary"
(
  cd "$ROOT_DIR"
  swift build -c release
)

[[ -f "$BUILD_EXECUTABLE" ]] || fail "Build output not found: $BUILD_EXECUTABLE"

log "→ Stopping running GroqDictate process"
pkill -x "GroqDictate" 2>/dev/null || true
sleep 0.3

log "→ Installing binary into app bundle"
install -m 755 "$BUILD_EXECUTABLE" "$APP_EXECUTABLE"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  require_command codesign
  log "→ Signing app with identity: $CODESIGN_IDENTITY"
  codesign -s "$CODESIGN_IDENTITY" -f --deep "$APP_PATH"
else
  log "→ Skipping codesign (set CODESIGN_IDENTITY to enable signing)"
fi

if [[ "$LAUNCH_AFTER_BUILD" == "1" ]]; then
  log "→ Launching app"
  open "$APP_PATH"
else
  log "→ Launch skipped (LAUNCH_AFTER_BUILD=$LAUNCH_AFTER_BUILD)"
fi

log "✅ Build/install complete"
