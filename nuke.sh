#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.groqdictate}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-com.groqdictate}"
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-groq-api-key}"
TMP_BASE="${TMPDIR:-/tmp}"

log() {
  printf '%s\n' "$*"
}

log "→ Stopping GroqDictate"
pkill -x "GroqDictate" 2>/dev/null || true
sleep 0.3

log "→ Removing API key from Keychain"
security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null || true

log "→ Removing UserDefaults domain: $BUNDLE_ID"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

log "→ Removing cache and HTTP storage"
paths=(
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Caches/groq-dictate"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/groq-dictate"
)

for path in "${paths[@]}"; do
  rm -rf "$path"
done

log "→ Removing temporary audio files"
rm -f "$TMP_BASE/groqdictate.wav" "$TMP_BASE/groqdictate.flac"

log "→ Resetting TCC permissions"
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null || true

log "✅ Clean slate complete"
log "Run: open /Applications/GroqDictate.app"
