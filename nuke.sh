#!/bin/bash
# Nuke all GroqDictate state for a clean-slate fresh install experience.
set -e

echo "Killing GroqDictate..."
pkill -f GroqDictate 2>/dev/null || true
sleep 0.5

echo "Deleting Keychain entry (service: com.groqdictate, account: groq-api-key)..."
security delete-generic-password -s "com.groqdictate" -a "groq-api-key" 2>/dev/null || true

echo "Deleting UserDefaults (groq-model, mic-uid, input-gain)..."
defaults delete com.groqdictate 2>/dev/null || true

echo "Deleting caches and HTTP storage..."
rm -rf ~/Library/Caches/com.groqdictate
rm -rf ~/Library/Caches/groq-dictate
rm -rf ~/Library/HTTPStorages/com.groqdictate
rm -rf ~/Library/HTTPStorages/groq-dictate

echo "Deleting temp audio files..."
rm -f "${TMPDIR}groqdictate.wav" "${TMPDIR}groqdictate.flac"

echo "Resetting Microphone permission..."
tccutil reset Microphone com.groqdictate 2>/dev/null || true

echo "Resetting Accessibility permission..."
tccutil reset Accessibility com.groqdictate 2>/dev/null || true

echo ""
echo "✅ Clean slate. Run: open /Applications/GroqDictate.app"
