# Architecture Notes

This document captures non-obvious implementation decisions and runtime constraints. It is not a file-by-file code map.

## Code ownership

- `Sources/App/` coordinates app lifecycle, workflow state, and cross-service decisions.
- `Sources/Core/` owns constants, strings, config, keychain helpers, and diagnostics primitives.
- `Sources/Services/` owns integrations with audio, focus, hotkeys, permissions, paste target inspection, networking, and transcription.
- `Sources/UI/` renders the floating panel and Settings UI.

Keep business transitions out of UI views. Keep user-facing copy out of low-level services where possible.

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

## Audio pipeline

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
