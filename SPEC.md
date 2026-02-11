# GroqDictate — Product Behavior Specification

## 0. Product Intent

GroqDictate is a macOS menu bar dictation tool that should feel like a **single global shortcut**, not a traditional app.

Core loop:
1. Press **Right ⌘** to start recording.
2. Press **Right ⌘** again to stop and transcribe.
3. Transcript is pasted into the app the user is currently working in.

Design priorities:
- **Minimalism**: no dock/app-switcher presence during normal use.
- **Speed**: low start latency and low stop→paste latency.
- **Predictability**: focus, keyboard handling, and errors behave consistently.
- **Polish**: no raw backend noise in UI, clear next actions.

---

## 1. UX Principles

1. **User intent beats implementation convenience**.
   - If user changes app while recording/processing, paste should follow user’s latest context.
2. **Settings flow and dictation flow are independent**.
   - Returning from Settings should not corrupt dictation target behavior.
3. **Cancel is immediate when system allows it**.
   - Esc should dismiss active dictation states whenever event capture is available.
4. **Errors are actionable, not technical dumps**.
   - Show concise friendly messages; keep raw details for logs.
5. **Accessory app constraints are acknowledged explicitly**.
   - Some keyboard behavior is OS-limited (permissions, Secure Input).

---

## 2. Implementation Principles & Code Ownership

Implementation is split by responsibility:
- `Sources/App/` — app lifecycle orchestration and state transitions
- `Sources/Core/` — constants, shared strings, config/keychain primitives
- `Sources/Services/` — system integrations (audio, hotkeys, focus, networking)
- `Sources/UI/` — panel + settings rendering and view-local behavior

Rules:
1. `App` coordinates state; it does not render complex UI directly.
2. `Services` own side-effecting integrations; they do not decide UX copy.
3. `UI` renders state; it does not own business transition logic.
4. `Core` remains dependency-light and free of app lifecycle side effects.

---

## 3. App Mode & Surface Area

- App activation policy: `.accessory` (LSUIElement-style behavior).
- Primary UI surfaces:
  1. Menu bar item
  2. Floating non-activating panel (recording/processing/errors)
  3. Settings window
- No persistent main window.

---

## 4. First Launch & Onboarding

### 4.1 First launch without API key
- Show Settings window as onboarding.
- API key field is focused and ready for paste.
- Cmd+V, Cmd+C, Cmd+X, Cmd+A must work in text fields.

### 4.2 Validation on save
- API key cannot be empty.
- API key must start with `gsk_`.
- On valid save, persist:
  - API key in Keychain
  - model/mic/gain in UserDefaults

### 4.3 Closing without save
- X closes Settings, no save.
- App remains in menu bar.
- Next launch reopens onboarding until valid key exists.

---

## 5. Settings Behavior

### 5.1 Opening
Settings can be opened via:
- menu bar item
- Cmd+,
- relaunch while idle

### 5.2 Focus behavior
- On open: capture `settingsReturnApp` (last non-GroqDictate frontmost app at open time).
- On close (Done or X): reactivate `settingsReturnApp` when possible.
- Settings focus lifecycle is independent from dictation target lifecycle.

### 5.3 Single settings context
- Opening Settings repeatedly should not create user-confusing duplicate settings contexts.

---

## 6. Permissions Model

### 6.1 Microphone
- Requested after successful onboarding save.
- If denied/restricted: recording cannot start; user gets actionable message and deep-link to microphone privacy pane.

### 6.2 Accessibility / event capture
- App attempts privileged global event capture for reliable key handling.
- If unavailable, fallback behavior remains usable for core flow where system permits.

### 6.3 System constraints
- Under Secure Input or missing permissions, global key interception can be reduced or unavailable.
- App must fail gracefully with clear user-facing guidance, not silent failure.

---

## 7. Keyboard Interaction Contract

### 7.1 Right ⌘
- Idle → Start recording
- Recording → Stop and transcribe
- Processing → ignored
- Error state → executes error-specific action (retry/new/settings/etc.)

### 7.2 Esc
- Recording → cancel and dismiss
- Processing → cancel UI state and ignore late callback
- Error → dismiss and cleanup
- Idle → pass through

Esc is **best-effort global cancel** subject to macOS event-capture limitations.

---

## 8. Dictation Focus Model (Authoritative)

GroqDictate maintains two independent focus references:
1. `settingsReturnApp` — used only for settings close behavior.
2. `dictationTargetApp` — used only for paste/cancel return behavior.

### 8.1 Dictation target policy (dynamic)
- On recording start, initialize `dictationTargetApp` to current non-self frontmost app.
- While recording/processing, update `dictationTargetApp` whenever user activates another non-self app.
- Reopen events must not accidentally overwrite target with GroqDictate itself.

Result: transcript pastes into the app the user is most recently working in.

### 8.2 Failure tolerance
- If target app terminates before paste, app must not crash.
- Transcript remains in clipboard; app falls back safely.

---

## 9. Floating Panel Specification

### 9.1 Window behavior
- `NSPanel` non-activating
- floating level
- joins all Spaces
- does not steal key focus from user app
- excluded from standard window cycling/exposé contexts where appropriate

### 9.2 Lifecycle
- Created once and reused.
- `show()` repositions and orders front.
- `dismiss()` resets visual state and hides (no destroy/recreate cycle).

### 9.3 Visual states
1. Recording
   - top: live waveform
   - bottom-left: recording label
   - bottom-right: esc hint
2. Processing
   - top: shimmer animation
   - bottom-left: transcribing label
   - bottom-right: esc hint
3. Error
   - top: concise friendly message
   - bottom-left: context action if available
   - bottom-right: esc dismiss hint

No raw JSON or backend payload text is shown verbatim.

---

## 10. Recording & Audio Pipeline

- Audio format: 16kHz, mono, 16-bit PCM WAV.
- Input gain applied in callback path.
- Optional specific mic selection supported.
- Temp file location: `$TMPDIR`.
- Large recordings are compressed to FLAC before upload.
- Cleanup policy:
  - success: cleanup
  - cancel: cleanup
  - dismiss error: cleanup
  - retryable error: preserve last file for retry

---

## 11. Transcription Network Behavior

- Endpoint: `POST /openai/v1/audio/transcriptions`
- Session tuned with explicit request/resource timeouts.
- Warm connection strategy at startup for first-request latency reduction.
- Retry policy for transient transport failures (timeout/connection-loss class).

---

## 12. Error Handling Policy

### 12.1 Sources of error
- transport/network failures
- HTTP status errors
- empty/invalid transcription body
- local read/write/audio failures

### 12.2 Groq status coverage (minimum)
- 400 bad request
- 401 unauthorized
- 403 forbidden (including account/org restrictions)
- 404 not found
- 413 payload too large
- 422 unprocessable
- 424 failed dependency
- 429 rate limit
- 498 capacity exceeded
- 500/502/503 server errors

### 12.3 UI mapping requirements
- Every error state must map to:
  - concise top-line message
  - optional action (`retry`, `new`, `settings`)
  - Esc dismiss behavior

### 12.4 Message extraction
When response body includes structured error JSON, prefer:
1. `error.message` (sanitized)
2. fallback to status-based friendly text
3. never display full raw payloads directly in panel

### 12.5 Retry categories
- Retryable: timeout, transient network, 429, 500/502/503, temporary capacity issues
- New recording required: too large (413)
- Settings-required: invalid auth/config (401 and relevant config failures)

---

## 13. Reopen / Relaunch / Quit

### 13.1 Reopen while idle
- Open Settings.

### 13.2 Reopen while recording/processing/error panel visible
- Do not disrupt active dictation state.
- Bring panel to user attention (non-destructive behavior).
- Preserve dictation target intent.

### 13.3 Quit and relaunch
- With saved key: app initializes ready state.
- Without saved key: onboarding settings reappears.

---

## 14. Menu Bar

Menu includes:
- informational shortcut hints
- Settings… (Cmd+,)
- Quit (Cmd+Q)

Menu interactions must not destabilize active dictation state.

---

## 15. Performance & Perceived Speed

Targets:
- fast panel appearance after trigger
- low stop→paste latency
- no unnecessary blocking operations on main thread in critical interaction path

Perceived performance:
- processing animation should feel responsive but not jittery
- state transitions should be immediate and visually coherent

---

## 16. Reliability Constraints & Non-Goals

### 16.1 Explicit constraints
- Global key capture is limited by macOS permissions and Secure Input contexts.
- App must communicate these limits clearly.

### 16.2 Non-goals (for now)
- full long-audio chunking pipeline
- complex background job orchestration
- broad multi-window UI surface

---

## 17. Acceptance Criteria (Release Gate)

A build is releasable only if:
1. Focus/paste target behavior matches dynamic-target policy across app/space switching.
2. Esc cancel behavior is correct where event capture is available, and graceful where unavailable.
3. Error UI is clean/actionable, including 403 restricted-account scenarios.
4. Success/cancel/retry flows do not leak temp files or crash under repeated usage.
5. Reopen/relaunch behavior does not corrupt active dictation state.
6. Module boundaries remain intact (`App`, `Core`, `Services`, `UI`) with no ownership leakage.

---

## 18. Source of Truth Relationship

- This file defines expected product behavior.
- `QA.md` is the executable verification plan for this behavior.
- If behavior changes, update **both** spec and QA together in the same revision.
