# GroqDictate

GroqDictate is a small macOS menu bar dictation app.

Press **Right ⌘** to start recording and press it again to stop. The app transcribes with **Groq Whisper**, writes the transcript to your clipboard, and tries to paste it into the app you were working in.

## For Users

### What you need

- macOS 14+
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

## For Developers

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
