# Verification

Automated tests should cover high-value behavior and edge cases. Manual checks should stay focused on macOS behavior that tests cannot reliably prove: permissions, focus, global hotkeys, clipboard history, and real Groq transcription.

## Test philosophy

Prefer tests that verify observable behavior a user, caller, or maintainer depends on:

- accepted/rejected Settings saves;
- transcription request shape that affects Groq behavior;
- user-visible error mapping;
- retry/cancel outcomes;
- clipboard/paste disposition decisions;
- diagnostics sanitization and high-value metadata.

Avoid tests that mostly lock in private helpers, internal state, view structure, mocks, or code coverage without protecting product behavior.

## Standard commands

Run signed local tests:

```bash
make test
```

Run full automation validation:

```bash
make validate
```

Run a fresh debug app with persistent diagnostics:

```bash
make dev RESET=1 FORCE=1 DEBUG_PERSIST=1
```

Use `project.yml` as the Xcode project source of truth. Run `make generate` only when target/project structure changes.

## Manual checks

Run these against a Debug or release-candidate build when the touched area warrants it.

### Core dictation path

1. Launch with a saved valid Groq API key.
2. Confirm the app starts in the menu bar without opening Settings.
3. Focus an editable field in another app.
4. Press Right `⌘` to start recording.
5. Press Right `⌘` again to stop.
6. Confirm the transcript auto-pastes when permissions allow it.
7. Confirm the transcript remains in the clipboard / clipboard history after auto-paste.
8. Press `Esc` while recording and while processing; confirm the panel dismisses and late work is ignored.

### Settings

1. Open Settings from the menu bar.
2. Confirm the API key field is focused immediately.
3. Change model, microphone, or gain; save; reopen Settings; confirm values persist.
4. Close Settings with the window close button after unsaved edits; confirm previous values remain unchanged.
5. If API/model validation changed, verify:
   - empty key is blocked;
   - non-`gsk_` key is blocked;
   - known invalid remote key shows an actionable error when network is available;
   - offline/unreachable validation still allows a locally valid `gsk_` key to save.

### Permission and degraded-mode paths

1. Deny **Input Monitoring** and relaunch.
2. Confirm startup diagnostics report degraded hotkey mode rather than app failure.
3. Verify Right `⌘` / `Esc` are best-effort: they may still work in normal apps, may still reach the focused app, and may fail in Secure Input or protected contexts.
4. Deny **Accessibility** and attempt a transcription into a text field.
5. Confirm GroqDictate avoids auto-paste, keeps the transcript in the clipboard, and does not imply paste succeeded.
6. Allow Accessibility but deny **PostEvent** when prompted.
7. Confirm GroqDictate keeps the transcript in the clipboard and shows the auto-paste-denied notice.

### Protected-context sanity

1. Put focus in a password field or another Secure Input context.
2. If degraded hotkey mode is active, confirm missing hotkey detection is treated as expected OS behavior.
3. Return to a normal editable app and confirm hotkeys recover there without relaunching.

### Diagnostics smoke check

After a debug run with `DEBUG_PERSIST=1`, inspect:

```text
~/Library/Application Support/GroqDictate/Diagnostics/diagnostics.jsonl
```

Confirm logs include useful context for the exercised path without exposing API keys, transcript text, prompt text, or sensitive paths.

### Release smoke checklist

1. Run `make validate`.
2. Re-run the core dictation path on the candidate build.
3. Re-run at least one denied permission path and one degraded hotkey path.
4. Confirm menu copy, notices, README, and docs match observed behavior.
