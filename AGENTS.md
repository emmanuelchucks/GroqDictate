# GroqDictate Agent Notes

Keep this file limited to constraints that are easy to violate and expensive to rediscover. The code owns ordinary implementation detail.

## Build and repository

- `project.yml` is the Xcode project source of truth. Run `make generate` after adding or removing source files and keep `GroqDictate.xcodeproj` synchronized.
- Use `make test` for signed local tests and `make validate` for the unsigned automation path. `make dev DEBUG_PERSIST=1` installs and launches the current debug build.
- Do not run `make reset` casually. It deletes preferences, Keychain configuration, permissions, diagnostics, and retained debug audio.
- Tests should protect user behavior, owned contracts, or meaningful failures—not private implementation shape.

## Product invariants

- GroqDictate is a one-shortcut menu bar tool. Prefer reliability improvements over new workflow surfaces.
- A successful transcript is written to the clipboard before paste is attempted and remains there afterward. Do not restore the old clipboard by default.
- Settings return focus and the live dictation target are separate concepts. During recording and processing, the target follows the latest non-GroqDictate app the user activates.
- Auto-paste is best-effort Cmd-V. Browser fields often work even when Accessibility cannot prove editability, so do not gate paste on focused-element inspection.
- Permission and Secure Input failures must degrade to short, honest UI states rather than pretending an action succeeded.

## Audio

- Capture is 16 kHz mono Int16 PCM. FLAC is used only as lossless upload compression for larger files.
- Bluetooth input may physically expose only 8 kHz. Upsampling and gain cannot restore missing bandwidth or improve signal-to-noise ratio.
- The input queue is prepared, then stopped while idle to avoid a permanent macOS microphone indicator. Wireless devices may need a few hundred milliseconds to resume; waveform movement is the speak-now cue.
- Normal stop drains queued buffers. Cancel stops promptly. Do not reintroduce leading/trailing silence trimming or VAD-based boundary cuts: quiet first/last words matter more than small upload savings.
- Retryable transcription failures retain the recording for manual retry. Success, cancel, and non-retryable cleanup remove temporary sessions.
- Generic denoising, normalization, Voice Processing, smaller buffers, and client-side chunking are not assumed improvements. Representative tests showed that altered/prompted decoding can omit or invent clauses; add audio processing only with same-audio evidence on the target hardware.

## Transcription accuracy

- Use Groq `whisper-large-v3` with `language=en`, `temperature=0`, verbatim output, and whole-file requests. Groq's free tier has sustained the real workload; ElevenLabs Scribe was more accurate in a blind review but exhausted its monthly credits after about a day of normal use.
- Word Hints are visible user preference data in `UserDefaults`. Normalize and deduplicate comma/newline-separated entries, cap the normalized value at 500 characters, and never ship owner-specific defaults.
- With nonempty hints, request raw and prompted Whisper candidates concurrently, then ask the text-only selector to return A or B unchanged. Selection failure falls back to raw; one successful transcription survives failure of the other. Empty hints use one request.
- Do not add general LLM cleanup by default. Controlled results removed repetitions and changed meaning. Candidate selection may choose an existing transcript but must never merge, rewrite, or polish it.
- Whole-file transcription remains the default. Overlapping ~30-second chunks did not recover a severely degraded recording and introduced merge/boundary complexity.
- Provider marketing benchmarks are not product evidence. Compare providers using blind review and sustained real usage; prioritize meaning-changing errors, reliability, quota behavior, and total cost over aggregate WER.

## Diagnostics and privacy

- Never log API keys, transcript text, Word Hints, prompts, sensitive paths, or retained-audio contents.
- Useful diagnostics include provider/model, request latency, retry reason, request ID, sanitized rate-limit context, capture level/clipping, target app category, and paste disposition.
- Persistent debug diagnostics live at `~/Library/Application Support/GroqDictate/Diagnostics/diagnostics.jsonl`. Retained audio and private benchmark results must stay outside the repository.

## Manual proof after relevant changes

Exercise only the touched risks, but the critical assembled path is:

1. Focus another app, start/stop with Right Command, and confirm paste plus clipboard persistence.
2. Cancel recording and processing with Esc; late callbacks must not paste.
3. Save/reopen Settings, including empty and nonempty Word Hints.
4. Verify denied Accessibility/PostEvent leaves the transcript in the clipboard with accurate guidance.
5. Inspect diagnostics for useful metadata and absence of sensitive text.
