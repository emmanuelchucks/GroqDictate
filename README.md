# GroqDictate

GroqDictate is a focused Groq Whisper dictation app for macOS and iPhone.

On macOS, press **Right ⌘** to record, transcribe, copy, and paste into the app where you were working. On iPhone, recordings are preserved locally in durable five-minute segments before transcription, with retryable processing for long or interrupted sessions.

## For Users

### What you need

- macOS 14+ or iOS 17+
- A Groq API key (`gsk_...`)

### First-time setup

1. Launch the app.
2. Open Settings and enter your Groq API key.
3. Grant **Microphone** permission.
4. Grant **Accessibility** permission so GroqDictate can inspect the focused field and auto-paste.
5. Grant **Input Monitoring** for the most reliable global Right `⌘` and `Esc` hotkeys.

If Input Monitoring is denied, GroqDictate falls back to best-effort key monitoring. In that mode, shortcuts may pass through to the focused app, and Secure Input/protected contexts can block detection.

If auto-paste is unavailable or denied, the transcript remains in your clipboard and GroqDictate shows a notice.

### Keyboard shortcuts

- Right ⌘: start/stop dictation
- Esc: cancel/dismiss

Wireless Bluetooth microphones can take a moment to wake on macOS. If the panel waveform is flat at first, begin speaking when it starts moving. Wired/USB microphones generally avoid this wake-up delay.

### iPhone recording safety

- Start and stop recording from the in-app control.
- A fully completed transcript is copied to the system clipboard automatically; manual copy remains available from the recording detail.
- Original audio is retained after successful transcription.
- Long recordings roll into five-minute segments without deactivating background audio.
- Failed or offline transcriptions remain available for manual retry; segments with no audio are identified as non-retryable.
- Calls and alarms finalize the current segment before the app attempts to resume.
- Phantom phrases Whisper writes over silence ("Thank you.", "Thank you for watching.") are removed when no one was speaking; the original text stays available.
- Optional spelling fixes correct names Whisper keeps mishearing.
- An accepted call can create a recording gap because iOS gives the call control of the microphone; audio captured before it remains safe.

## For Developers

The macOS and iOS apps are separate targets in the same generated Xcode project. Platform-specific workflows remain isolated under `Sources/` and `iOS/Sources/`, while product identity and Groq behavior stay coordinated in one repository.

### Requirements

- macOS 14+
- Xcode 26.x (validated on Xcode 26.3, with Command Line Tools)
- XcodeGen 2.45+

### Common commands

```bash
make doctor
make generate
make test
make validate
make dev
make ios-build
```

`project.yml` is the source of truth for the Xcode project. Regenerate `GroqDictate.xcodeproj` with `make generate` after changing targets or build settings.

Prefer the Makefile targets over ad hoc `xcodebuild` commands. `make test` runs signed local Debug tests; `make validate` is the unsigned automation validation path.

Fresh local run with reset:

```bash
make dev RESET=1 FORCE=1
```

Enable persistent debug diagnostics:

```bash
make dev RESET=1 FORCE=1 DEBUG_PERSIST=1
```

Structured diagnostics journal:

```text
~/Library/Application Support/GroqDictate/Diagnostics/diagnostics.jsonl
```

### Release build

```bash
make release \
  DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-notarytool-profile"
```

This builds, signs, notarizes, staples, verifies, and outputs `dist/GroqDictate.app` and `dist/GroqDictate.zip`.

## Project docs

- Product direction: [`docs/product.md`](docs/product.md)
- Architecture notes: [`docs/architecture.md`](docs/architecture.md)
- Verification: [`docs/verification.md`](docs/verification.md)

## Privacy

- API keys are stored in macOS Keychain.
- Audio is written to temporary files during processing and cleaned up by app flow.
- Diagnostics are structured for debugging, with secrets and sensitive text sanitized.

## License

MIT (`LICENSE`).
