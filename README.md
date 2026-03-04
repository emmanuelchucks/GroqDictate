# GroqDictate

GroqDictate is a macOS menu bar dictation app.

Press **Right ⌘** to start recording, press it again to stop, transcribe with **Groq Whisper**, and auto-paste into the active app when permissions allow. If auto-paste is unavailable, GroqDictate keeps the transcription in your clipboard instead.

## Requirements

- macOS **14.0+**
- Xcode **16+** (with Command Line Tools)
- Groq API key (`gsk_...`)

For release distribution (signing + notarization):
- Paid Apple Developer account
- Developer ID Application certificate installed locally
- `notarytool` keychain profile configured

## Pipeline (simplified)

### Day-to-day development

```bash
make dev
```

That builds Debug, installs to `/Applications/GroqDictate.app`, and runs it.

If you want a clean-room run first:

```bash
make dev RESET=1 FORCE=1
```

If you want long-running dogfood logs persisted to disk:

```bash
make dev RESET=1 FORCE=1 DEBUG_PERSIST=1
```

### Full release (standard Developer ID flow)

```bash
make release \
  DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-notarytool-profile"
```

That performs: Release build → sign (hardened runtime + secure timestamp) → zip for notarization → notarize → staple → verify → rebuild the final distributable ZIP from the stapled app.

To also install the final notarized app:

```bash
make release \
  DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  INSTALL=1
```

For release dogfooding with persistent debug logs enabled:

```bash
make release \
  DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  INSTALL=1 DEBUG_PERSIST=1
```

### Full local state reset

```bash
make reset FORCE=1
```

## Tooling sanity check

```bash
make doctor
```

## First-time setup

1. Launch the app.
2. Open Settings and enter your Groq API key.
3. Grant **Microphone** in `System Settings > Privacy & Security > Microphone` so GroqDictate can record audio.
4. Grant **Accessibility** in `System Settings > Privacy & Security > Accessibility` so GroqDictate can inspect the focused field and participate in auto-paste.
5. Grant **Input Monitoring** in `System Settings > Privacy & Security > Input Monitoring` for the most reliable global hotkeys. Without it, GroqDictate falls back to best-effort hotkey monitoring: Right `⌘` and `Esc` may still reach the focused app or be blocked by protected contexts such as Secure Input.
6. On the first transcription into an editable field, macOS may separately ask for auto-paste / PostEvent control. If you deny it, GroqDictate copies the transcription to the clipboard and you can re-enable auto-paste from `System Settings > Privacy & Security > Accessibility`.
7. (Optional) Enable **Launch at Login** from the menu bar.

## Persistent debug logging

When `DEBUG_PERSIST=1` is used, debug logging is enabled via app defaults and survives relaunch/login.

Log file path:

```text
~/Library/Logs/GroqDictate/app.log
```

## Keyboard shortcuts

- **Right ⌘** — start/stop dictation
- **Esc** — cancel/dismiss

If Input Monitoring is denied or macOS blocks the event tap, GroqDictate runs hotkeys in degraded mode using NSEvent monitors. Core dictation can still work, but shortcuts become best-effort rather than fully intercepted.

## Distribution notes

- `make dev` produces unsigned local development installs.
- `make release` produces `dist/GroqDictate.app` and `dist/GroqDictate.zip`, with the ZIP rebuilt from the stapled app after notarization.
- Gatekeeper-friendly distribution requires `make release` with Developer ID + notarization.

## Privacy

- API keys are stored in macOS Keychain.
- Audio is written to temporary files during processing and cleaned up by app flow.

## License

MIT (see `LICENSE`).
