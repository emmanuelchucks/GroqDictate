#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building..."
swift build -c release 2>&1 | grep -E "Build|error"

echo "Installing..."
pkill -f GroqDictate 2>/dev/null || true
sleep 0.5
cp .build/release/GroqDictate /Applications/GroqDictate.app/Contents/MacOS/GroqDictate

echo "Signing..."
codesign -s "Apple Development: echucks19@gmail.com (V5SLN447NT)" -f --deep /Applications/GroqDictate.app

echo "Launching..."
open /Applications/GroqDictate.app

echo "✅ Done"
