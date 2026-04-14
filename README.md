# GroqDictate

GroqDictate is a macOS menu bar dictation app.

Press **Right ⌘** to start recording and press it again to stop. The app transcribes with **Groq Whisper** and tries to paste into the active app. If auto-paste is unavailable, the transcript is kept in your clipboard.

## For Users

### What you need

- macOS 14+
- A Groq API key (`gsk_...`)

### Run the app locally

```bash
make dev
```

This builds Debug, installs to `/Applications/GroqDictate.app`, and runs it.

### First-time setup

1. Launch the app.
2. Open Settings and enter your Groq API key.
3. Grant **Microphone** permission.
4. Grant **Accessibility** permission for focused-field checks and auto-paste.
5. Grant **Input Monitoring** for the most reliable global Right `⌘` and `Esc` hotkeys.

If Input Monitoring is denied, GroqDictate falls back to best-effort `NSEvent` monitoring. In this degraded mode, shortcuts may pass through to the focused app, and Secure Input/protected contexts can block detection.

If auto-paste (PostEvent) is denied, GroqDictate copies the transcript to clipboard and shows a notice.

### Keyboard shortcuts

- Right ⌘: start/stop dictation
- Esc: cancel/dismiss

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
make run
```

`project.yml` is the source of truth for the Xcode project. Regenerate `GroqDictate.xcodeproj` with `make generate` after changing targets or build settings.

Prefer the Makefile targets over ad hoc `xcodebuild` commands for local work. `make test` runs signed local Debug tests; `make validate` is the unsigned automation validation path.

Run signed local tests:

```bash
make test
```

Run a single signed local test:

```bash
make test TEST_ONLY=GroqDictateTests/HotkeyMonitorTests
```

Fresh local run with reset:

```bash
make dev RESET=1 FORCE=1
```

This clears app-owned local state, temporary recordings/uploads, preferences, keychain API key, diagnostics, and privacy grants. macOS-managed Login Items entries may still need to be removed manually in System Settings.

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

This builds, signs, notarizes, staples, verifies, and outputs:

- `dist/GroqDictate.app`
- `dist/GroqDictate.zip`

Install the final notarized app:

```bash
make release \
  DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-notarytool-profile" \
  INSTALL=1
```

## Privacy

- API keys are stored in macOS Keychain.
- Audio is written to temporary files during processing and cleaned up by app flow.

## License

MIT (`LICENSE`).
