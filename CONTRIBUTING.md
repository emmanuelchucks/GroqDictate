# Contributing

Use focused changes and explain the user-visible reason for them. Read [`AGENTS.md`](AGENTS.md) before changing audio, transcription, focus, paste, permissions, or diagnostics behavior.

Requirements: macOS 14+, Xcode 26.x, and XcodeGen 2.45+.

```bash
make doctor
make test
make validate
make dev
```

`project.yml` is the Xcode project source of truth. Prefer Make targets over ad hoc `xcodebuild` commands. Run a focused suite with:

```bash
make test TEST_ONLY=GroqDictateTests/HotkeyMonitorTests
```

Add durable tests for meaningful behavior or failure boundaries. For a pull request, describe the motivation, verification, remaining risks, and screenshots only when the UI visibly changed.
