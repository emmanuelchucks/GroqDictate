# GroqDictate QA

## Manual validation

Run these checks against a Debug or release-candidate build.

### Core path

1. Launch with a saved API key and confirm the app starts in the menu bar without opening Settings.
2. Press Right `⌘` to start recording, press it again to stop, and confirm the transcript auto-pastes into an editable field when all permissions are granted.
3. Press `Esc` while recording and while processing; confirm the panel dismisses and late work is ignored.

### Settings window

1. Open Settings from the menu bar.
2. Confirm the API key field is focused immediately.
3. Confirm the layout stays stable at the default compact size with long model names and the key hint visible.
4. Change model, microphone, and gain; save; reopen Settings; confirm values persist.
5. Close Settings with the window close button after making unsaved edits; confirm previous values remain unchanged.

### Permission and degraded-mode paths

1. Deny **Input Monitoring** and relaunch.
2. Confirm startup logs report degraded hotkey mode rather than failure.
3. Verify Right `⌘` / `Esc` are best-effort: they may still work in normal apps, may still reach the focused app, and may fail in Secure Input or other protected contexts.
4. Deny **Accessibility** and attempt a transcription into a text field.
5. Confirm GroqDictate avoids auto-paste, keeps the transcript in the clipboard, and does not imply paste succeeded.
6. Allow Accessibility but deny **PostEvent** when prompted.
7. Confirm GroqDictate keeps the transcript in the clipboard, shows the auto-paste-denied notice, and optionally opens the correct System Settings pane if requested.

### Protected-context sanity checks

1. Put focus in a password field or other Secure Input context.
2. If degraded hotkey mode is active, confirm missing hotkey detection is treated as expected OS behavior.
3. Return to a normal editable app and confirm hotkeys recover there without relaunching.

## Release checklist

1. Run:

```bash
xcodebuild -project GroqDictate.xcodeproj -scheme GroqDictate -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GroqDictate.xcodeproj -scheme GroqDictate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

2. Re-run the `Core path` checks above on the candidate build.
3. Re-run at least one denied permission path and one degraded hotkey path.
4. Confirm menu copy, notices, and README instructions still match observed runtime behavior.
