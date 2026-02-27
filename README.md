# GroqDictate

GroqDictate is a macOS menu bar dictation app.

Press **Right ⌘** to start recording, press it again to stop, transcribe with **Groq Whisper**, and paste into the active app.

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

That performs: Release build → sign (hardened runtime + secure timestamp) → package → notarize → staple → verify.

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
3. Grant Microphone permission.
4. Grant Accessibility permission for more reliable global key handling.
5. (Optional) Enable **Launch at Login** from the menu bar.

## Persistent debug logging

When `DEBUG_PERSIST=1` is used, debug logging is enabled via app defaults and survives relaunch/login.

Log file path:

```text
~/Library/Logs/GroqDictate/app.log
```

## Keyboard shortcuts

- **Right ⌘** — start/stop dictation
- **Esc** — cancel/dismiss

## Distribution notes

- `make dev` produces unsigned local development installs.
- Gatekeeper-friendly distribution requires `make release` with Developer ID + notarization.

## Privacy

- API keys are stored in macOS Keychain.
- Audio is written to temporary files during processing and cleaned up by app flow.

## License

MIT (see `LICENSE`).
