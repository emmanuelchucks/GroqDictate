# Product Direction

GroqDictate is a macOS menu bar dictation tool that should feel like a single global shortcut, not a traditional app.

## Core workflow

1. Press **Right ⌘** to start recording.
2. Speak.
3. Press **Right ⌘** again to stop.
4. Transcribe with Groq Whisper.
5. Put the transcript where the user was working.
6. Leave the transcript in the clipboard for reuse and clipboard history.

The product should stay boring, fast, reliable, and easy to reason about.

## Product principles

- **One primary path**: one shortcut, one dictation flow, one small Settings surface.
- **Reliability over features**: improvements should make the core path more predictable, not turn the app into a dictation suite.
- **Clipboard persistence is intentional**: after successful transcription, the transcript should remain in the clipboard even if auto-paste or a future direct insertion path succeeds.
- **No clipboard restoration by default**: restoring the previous clipboard would break reuse and clipboard-history workflows.
- **User context wins**: if the user changes apps while recording/processing, the transcript should target the latest user context.
- **Compact copy is part of the character**: user-facing strings should be short, calm, and direct unless extra words are clearly needed for safety or setup.
- **Actionable errors**: UI copy should be friendly and brief; raw backend details belong in diagnostics.
- **macOS limits are real**: Secure Input and permissions can block hotkeys or automation. The app should degrade clearly rather than pretend those limits do not exist.

## Focus and paste behavior

GroqDictate tracks dictation target separately from Settings focus. Settings should not corrupt where dictation paste goes.

Paste behavior is clipboard-first:

1. Write the transcript to the clipboard.
2. Try the best allowed insertion path.
3. If insertion is unavailable, leave the transcript in clipboard and tell the user.

Future insertion methods, such as Accessibility/direct insertion, must be additive. They must not replace clipboard persistence.

## Scope boundaries

In scope:

- Menu bar dictation.
- Right Command start/stop.
- Esc cancel/dismiss where macOS allows it.
- Groq cloud speech-to-text.
- A compact Settings window for API key, model, microphone, and gain.
- Diagnostics that help explain real failures without exposing secrets or transcript text.

Out of scope unless explicitly reprioritized:

- Always-on meeting transcription.
- Local/offline speech models.
- Full long-audio chunking pipeline.
- Broad multi-provider configuration.
- Large model/language management UI.
- Automatic previous-clipboard restoration.
- Complex multi-window app surfaces.

## Groq STT product choices

- Use Groq cloud STT as the primary transcription path.
- Prefer `whisper-large-v3-turbo` as the default model for short dictation latency/cost.
- Keep `whisper-large-v3` as the accuracy option.
- Do not keep the Distil Whisper option in the normal app.
- Omit the `language` request field so Groq auto-detects language.
- Keep `temperature = 0`; Groq recommends the default `0` for transcription/translation, and predictable dictation is the desired behavior.
- Do not expose prompt/vocabulary support unless it can be done as a simple visible setting with honest validation. Do not add hidden prompt settings.
