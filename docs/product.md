# Product Direction

GroqDictate is a focused dictation product for macOS and iPhone. The macOS app should feel like a single global shortcut; the iPhone app should feel like a trustworthy recorder whose audio cannot disappear because transcription failed.

## iPhone workflow

1. Start and stop recording from the in-app control.
2. Persist ordered audio segments throughout long recordings.
3. Finalize the current segment when calls, alarms, or route changes interrupt capture.
4. Transcribe each completed segment with bounded automatic retries.
5. Keep retryable uploads pending, distinguish segments that were never recorded, and keep every existing audio file available to share.
6. Remove phantom phrases Whisper writes over silence, keep Groq's original text beside the cleaned text, and assemble successful segments into one transcript with the user's spelling fixes applied.
7. Automatically copy a fully completed transcript to the system clipboard while keeping manual copy available.

Decided (Nov 2026):

- While paused, the big button stays Stop (it means the same thing in every state) and Resume is the smaller button.
- Each finished five-minute part is transcribed while recording continues, so long recordings have most of their text ready at Stop.
- A part cut off by the app being killed mid-recording must stay recoverable.
- Audio is never deleted automatically; the user deletes recordings by hand.
- The app shows nothing while working normally: no spinners, and only a slow transcription (over four seconds) says so. Notices clear themselves.

The iPhone app shares the macOS waveform icon, orange-on-near-black identity, and compact, calm error language. Native iPhone interaction conventions take precedence over visually cloning the macOS panel.

## macOS core workflow

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
- Full long-audio chunking pipeline in the macOS app.
- Broad multi-provider configuration.
- Large model/language management UI.
- Automatic previous-clipboard restoration.
- Complex multi-window app surfaces.

## Groq STT product choices

- Use Groq cloud STT as the primary transcription path.
- Prefer `whisper-large-v3` as the default model because dictation quality matters more than the small latency/cost win.
- Keep `whisper-large-v3-turbo` as the fast/cheap option.
- Do not keep the Distil Whisper option in the normal app.
- Send `language = en` by default for better English dictation accuracy and latency.
- Keep `temperature = 0`; Groq recommends the default `0` for transcription/translation, and predictable dictation is the desired behavior.
- Names are corrected after transcription with the user's visible "Spelling fixes" list, not with Whisper's prompt: a vocabulary prompt made Whisper drop or invent clauses. The iPhone's only prompt is the end of the previous five-minute part.
- Phantom phrases are removed from the text, never by cutting audio, and only where the built-in sound classifier hears no voice (`docs/transcript-cleanup.md`).
