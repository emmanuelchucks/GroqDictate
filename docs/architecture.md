# Architecture Notes

This document captures non-obvious implementation decisions and runtime constraints. It is not a file-by-file code map.

## Code ownership

- `Sources/App/` coordinates app lifecycle, workflow state, and cross-service decisions.
- `Sources/Core/` owns constants, strings, config, keychain helpers, and diagnostics primitives.
- `Sources/Services/` owns integrations with audio, focus, hotkeys, permissions, paste target inspection, networking, and transcription.
- `Sources/UI/` renders the floating panel and Settings UI.

Keep business transitions out of UI views. Keep user-facing copy out of low-level services where possible.

## iOS target

The iPhone app is a separate `GroqDictateIOS` target in the same repository. It owns a materially different capture workflow under `iOS/Sources/` rather than adding iOS conditionals to the macOS menu-bar code.

Its durable unit is a recording session containing ordered five-minute M4A segments and an atomically written JSON manifest. The manifest reserves each segment before capture. Normal rollover prepares the next recorder while the current recorder and audio session remain active, then swaps files synchronously without deactivating background audio. Completed segments move through `pending`, `transcribing`, `complete`, or retryable `failed`; a reserved segment with no audio becomes non-retryable `unavailable`. Source audio is never deleted automatically; the user can delete a recording that isn't recording or transcribing. On relaunch, interrupted capture and upload states are reconciled against the files that actually exist, and a session left recording or paused becomes finished with its saved parts pending.

Every manifest change goes through `SessionStore.update`, which applies one change to the latest saved copy inside the store actor, so recorder and transcription writes can't overwrite each other. Writers address segments by id. While a session is the current recording, its session-level state belongs to the recorder; transcription only sets it after stop. Transcription runs one pass per session at a time (`SerialRunner`); a request made during a pass gets another pass, so a segment that becomes pending mid-pass isn't skipped. A pass takes `pending` segments only; retry turns `failed` back into `pending`. Silence is a completed segment with empty text.

Audio-session interruptions and a lost audio route finalize the active segment and pause the session. Resume has one gate, `RecordingLifecycle.beginResume()`, which only `interrupted` passes. Three things go through it: the Resume button; iOS's interruption-ended notice when it says the app should resume; and returning to the app. The return path exists because alarms and timers often send no ended notice (seen on the iPhone XR, iOS 18.5). It's skipped while CallKit reports a call, since a call keeps the mic, and it fails quietly. A refused restart removes its reserved segment, keeps the session paused and logs iOS's error code. This preserves pre-interruption audio but cannot capture through an accepted phone call, which owns the microphone. Five-minute rollover is not an interruption and must keep the audio session continuously active, especially while the app is backgrounded.

The app records from its in-app control using a mixable audio-session configuration (`.playAndRecord`, `.default`, `.allowBluetoothHFP` plus `.mixWithOthers`). Apple supports explicit `.mixWithOthers` with `.playAndRecord`, but not with `.record`. Capture activates the session explicitly before `record()`, which only reports a Bool, so a refusal comes with iOS's reason; stop deactivates the session normally, and the app does not keep an idle recording session active.

The first iOS version sends bounded segments directly to Groq using a Keychain-stored API key. Optional vocabulary hints are stored as ordinary local settings, normalized to a conservative 500-character UI budget, and sent as Groq's `prompt` field on every segment. Groq documents a 224-token prompt maximum; the smaller character budget avoids adding a Whisper tokenizer solely for settings validation. When every segment of the session just stopped completes, the assembled nonempty transcript is automatically written to the system clipboard. In the foreground the recorder card says so for three seconds with a success haptic, then returns to idle; the list row marks the recording while its text is still on the clipboard (by the pasteboard's change count). The usual next step is switching to the app to paste into, and an app's haptics don't play in the background, so there a local notification (sound or vibration, plus a banner) says it instead. iOS may refuse pasteboard writes from the background: the pasteboard's change count shows whether the write took, and if not, the notification says "Tap to copy" and the copy happens when the app is next active. Manual copy remains available from session detail. Each transcription run holds a UIKit background task, since leaving the app to paste is the usual next step. Rate limits honour Groq's `retry-after` seconds up to 20 seconds, then leave the segment for manual retry. A backend may later own credentials and background jobs, but it must preserve the local durable queue and recovery contract.

iOS keeps bounded, local timing diagnostics in `Library/Application Support/GroqDictate/Diagnostics/` (`timing.jsonl` and one rotated file, at most 256 KiB each, excluded from backups). Events correlate recording and request UUIDs with attempt timing, HTTP status, retry decisions, transport phases, and app lifecycle transitions. They never include audio, transcript, vocabulary, credentials, response bodies, arbitrary errors, addresses, URLs, or unrestricted headers. Uploads share one `URLSession` so later segments and retries can reuse a warm connection; a retry after a transport failure calls `flush()` first so it opens a new connection rather than reusing a stalled one. `transcriptReady` records seconds from stop to text and the audio length; its code is 1 if the clipboard write took, plus 10 if the app was in the background. Transaction metrics record enough metadata to distinguish connection, upload, and response stalls without exposing request content.

Recorder UI is derived from an explicit `idle`, `starting`, `recording`, `stopping`, `interrupted` or `resuming` lifecycle, and after stop from the stopped session (transcribing, copied, no speech, or not transcribed with Retry). The card's status, detail and action rows are always laid out so it doesn't move between states. Resume is available only for `interrupted`; a normal stop enters `stopping` synchronously before recorder finalization so asynchronous persistence cannot momentarily present interruption UI.

Visual identity is shared with macOS: the waveform icon, near-black base, orange accent, compact status language, and calm actionable errors. Controls remain platform-native rather than reproducing the macOS floating panel literally.

## Runtime surfaces

GroqDictate is an accessory/menu bar app. The normal user-facing surfaces are:

- menu bar item;
- floating non-activating panel for recording, processing, notices, and errors;
- Settings window.

The panel should not steal typing focus from the app the user is dictating into.

## Focus model

The app maintains two separate focus concepts:

- `settingsReturnApp`: where to return after closing Settings.
- `dictationTargetApp`: where dictation output should go.

They are intentionally independent. Reopening Settings, closing Settings, or bringing the panel forward must not accidentally rewrite the dictation target.

During recording and processing, the dictation target follows the latest non-GroqDictate app the user activates. This matches user intent when they start recording in one app and switch to another before the transcript is ready.

## Clipboard-first insertion

Successful transcription writes to the clipboard before any paste attempt. This is intentional because:

- users may want to paste/reuse the transcript manually;
- clipboard history tools can capture it;
- clipboard fallback is reliable when auto-paste is blocked.

Current insertion is best-effort simulated Cmd+V after reactivating the target app. Do not require Accessibility to prove the focused element is editable before pasting; browser text fields often do not expose stable editable attributes even though normal Cmd+V works. If PostEvent permission prevents auto-paste, the transcript remains in clipboard and the user gets a notice.

Future direct insertion through Accessibility must stay additive:

1. write clipboard first;
2. try Cmd+V as the normal cross-app path;
3. use direct insertion only where it is clearly safer or more reliable;
4. fall back to clipboard-only notice.

Do not restore the previous clipboard by default.

## macOS audio pipeline

The app records 16 kHz mono 16-bit PCM WAV. After stop, it preserves the captured audio and may compress to FLAC when the file is large enough to justify the size/latency tradeoff.

The input AudioQueue is briefly prepared during runtime bootstrap, then stopped while idle so macOS does not show a persistent microphone indicator. Recording start restarts the prepared queue and shows the waveform panel immediately with only the cancel hint. The UI adds the normal recording label when nonzero input is observed, making waveform movement the speak-now cue for wireless devices that wake slowly. A constant warm input stream was tested and was reliable, but intentionally rejected as the default because it keeps macOS's microphone indicator on while idle.

Normal stop drains a small number of input buffers before finalizing the WAV, then stops idle input again. Cancel paths discard the active session promptly and stop idle input. Full input queue teardown is reserved for app shutdown or device reconfiguration.

Captured leading/trailing speech and interior pauses are preserved because dictation reliability is more important than shaving small uploads. Do not use local speech-boundary trimming; it can clip quiet first/last words. Temp files should be cleaned on success, cancel, and non-retryable cleanup paths. Retryable transcription failures preserve the last audio file so the user can retry without re-recording.

## Groq transcription request decisions

The app uses Groq's OpenAI-compatible transcription endpoint:

```text
POST https://api.groq.com/openai/v1/audio/transcriptions
```

Durable request choices:

- `response_format = verbose_json` because segment metadata helps diagnostics without changing the returned transcript.
- `temperature = 0` because Groq recommends the default `0` for STT and deterministic dictation is desirable.
- set `language = en` for the default English dictation path because Groq documents that providing the input language improves accuracy and latency.
- prefer `whisper-large-v3` by default; keep `whisper-large-v3-turbo` as the fast/cheap option.

Avoid hidden defaults/overrides for product behavior. If a future setting matters to users, it should be visible and understandable.

## Error and retry posture

Errors should become concise, actionable UI states. Diagnostics can keep sanitized technical details.

Important classes:

- auth/config: invalid key, restricted account, unavailable model;
- upload/input: too large, unprocessable audio, empty transcription;
- transient network/service: timeout, connection loss, rate limit, capacity, server errors;
- local system: microphone, permissions, clipboard, focus/paste automation.

Automatic retries should be bounded and cancellation-safe. Respect `Retry-After` for rate limits. After final failure, preserve the manual retry path for retryable transcription errors. Offline/DNS/connectivity failures should use compact retryable copy (`Check connection`) rather than falling through to a generic unexpected error.

## Diagnostics philosophy

Diagnostics exist to explain real support/debugging questions, not to collect noise.

They should help answer:

- Did the hotkey arrive, and in which state?
- Which app was the dictation target?
- Was the clipboard write successful?
- Why did paste auto-execute or fall back?
- Was audio silent, clipped, too long, or too large?
- Which model was used?
- What Groq status/request id/retry/rate-limit context was observed?
- Was Settings validation local, remote-successful, remote-invalid, or skipped because offline?

Privacy rules:

- never log raw API keys;
- never log raw transcript text;
- never log raw prompt/vocabulary text if that feature is added;
- sanitize sensitive paths and backend messages before persistence.

The JSONL diagnostics journal lives at:

```text
~/Library/Application Support/GroqDictate/Diagnostics/diagnostics.jsonl
```

Debug logging can be enabled for local runs with:

```bash
make dev RESET=1 FORCE=1 DEBUG_PERSIST=1
```
