# GroqDictate QA Plan

## Purpose
Validate that GroqDictate feels instant, predictable, and polished in real use:
- correct focus and paste target behavior
- reliable global keyboard handling
- actionable, clean error handling
- stable behavior across relaunches, spaces, and edge cases

This plan assumes the current product decisions:
1. **Dynamic paste target**: during recording/processing, paste target follows the **latest non-GroqDictate frontmost app**.
2. **Settings focus is separate** from dictation focus.
3. **Esc is best-effort global cancel** (blocked by OS constraints like Secure Input / missing permissions).
4. **Error UI is user-friendly** (no raw JSON blobs shown directly).

---

## Test Environment

- macOS 13+ (test latest stable + at least one prior major)
- At least two displays (if available)
- Multiple Spaces enabled
- Apps for target testing: Notes/TextEdit, Safari/Chrome, Terminal, Slack/Discord (or similar)
- One password/Secure Input context available (System Settings password field, password manager, etc.)

---

## A. First Launch & Onboarding

1. **Fresh state launch** (no API key): Settings window appears.
2. API key field is immediately focused; Cmd+V works.
3. Empty key + Done → blocked with clear validation error.
4. Non-`gsk_` key + Done → blocked with clear validation error.
5. Close onboarding with X (no save) → app remains in menu bar, no dictation available.
6. Relaunch after unsaved onboarding → Settings appears again.
7. Save valid key + settings → permission flow begins.
8. Mic prompt allow path proceeds cleanly.
9. Mic prompt deny path still proceeds to Accessibility request path.
10. Accessibility denied/ignored path leaves Right ⌘ usable where system allows.

Pass criteria: no dead-end state, no stuck window, no focus confusion.

---

## B. Settings Window Behavior

11. Open Settings from menu item.
12. Open Settings via Cmd+,.
13. Open Settings via relaunch while idle.
14. Done saves model/mic/gain.
15. X discards unsaved changes.
16. Closing Settings returns focus to app active **before** Settings opened.
17. Repeated open requests do not create UX confusion (single effective settings context).
18. API key change persists via Keychain.
19. Model/mic/gain persist via UserDefaults.

Pass criteria: settings focus lifecycle is isolated and deterministic.

---

## C. Recording Start / Panel UX

20. Right ⌘ while idle starts recording.
21. Panel appears quickly, top-center, non-activating.
22. Previously active app remains focused (cursor stays in text field).
23. Waveform animates and reacts to voice level.
24. Panel can be dragged.
25. Panel appears on all Spaces.
26. Repeated rapid Right ⌘ presses do not crash or create invalid state.

Pass criteria: panel is visible and responsive without stealing focus.

---

## D. Dynamic Paste Target (Core Focus Rules)

27. Start in App A, record, stop in App A → paste into App A.
28. Start in App A, switch to App B during recording, stop in B → paste into B.
29. Start in App A, stop (processing), switch to App B during processing → paste into B.
30. Start in App A, switch A→B→C before completion → paste into latest app C.
31. If latest target app terminates before paste, app does not crash; transcript remains in clipboard.
32. Relaunch app during recording does not corrupt target tracking.
33. Relaunch app during processing does not corrupt target tracking.

Pass criteria: paste destination matches latest intentional user context.

---

## E. Cancel / Esc Behavior

34. Esc during recording cancels, dismisses panel, no transcription.
35. Esc during processing dismisses panel and ignores late API callback.
36. Esc during error state dismisses and cleans temporary audio.
37. Esc behavior works across app switches while panel active (where permitted).
38. Esc behavior works across Spaces while panel active (where permitted).
39. Without required permissions, Esc limitations are graceful (not misleading).
40. Under Secure Input, key-capture limitations are treated as expected OS behavior.

Pass criteria: cancellation is immediate when technically available; limitations are predictable.

---

## F. Transcription Success Path

41. 3–5s recording transcribes and auto-pastes correctly.
42. 15–30s recording transcribes and auto-pastes correctly.
43. Clipboard contains transcript after successful paste.
44. After paste, focus is restored to current target app.
45. Very short recording (<1s) does not crash; returns text or clean no-speech error.

Pass criteria: success path is fast, clean, and repeatable.

---

## G. Error Handling UX (Friendly + Actionable)

### Structured mappings
46. 401 → invalid key message + Settings action.
47. 403 → account/org restricted message + actionable guidance (no raw JSON blob).
48. 413 → recording too large + new recording action.
49. 429 → rate-limited message includes wait hint/retry behavior.
50. 500/502/503 → unavailable/retry messaging.
51. timeout/network loss → retryable timeout/network messaging.
52. empty transcription → no speech detected + retry.

### Unknown and edge responses
53. Unknown HTTP with JSON body extracts concise `error.message` if present.
54. Unknown HTTP non-JSON body falls back to clean generic message.
55. Long backend messages are truncated/sanitized for panel readability.
56. Right ⌘ action in error state matches error type policy.
57. Esc from any error clears file and dismisses panel.

Pass criteria: no ugly raw payloads in UI; every error has clear next action.

---

## H. Audio + File Lifecycle

58. WAV file created during recording.
59. On success, temp audio files are cleaned up.
60. On cancel, temp audio files are cleaned up.
61. On error, last audio file is preserved for retry.
62. Retry uses preserved file and does not require re-record.
63. New recording after too-large error replaces old file.
64. FLAC conversion path works for large recordings.

Pass criteria: cleanup and retry semantics are correct and leak-free.

---

## I. Reopen / Relaunch / Quit Lifecycle

65. Reopen while idle opens Settings.
66. Reopen while recording brings panel to front (or equivalent non-disruptive behavior).
67. Reopen while processing does not interrupt active request.
68. Quit from menu/Cmd+Q exits cleanly.
69. Relaunch with saved key starts ready state.
70. Relaunch without key returns to onboarding.

Pass criteria: lifecycle transitions never break active dictation state.

---

## J. Menu Bar + Shortcuts

71. Waveform icon visible in menu bar.
72. Menu contains expected informational and action items.
73. Cmd+, opens Settings.
74. Cmd+Q quits app.
75. Left ⌘ behavior in other apps remains normal.
76. Right ⌘ trigger behavior does not produce stuck-modifier side effects.

Pass criteria: shortcuts feel native and non-invasive.

---

## K. Perceived Performance & Polish

77. Panel appears quickly after trigger (subjective “instant” feel).
78. Shimmer/processing animation feels responsive, not jittery.
79. First request latency is acceptable; subsequent requests not slower than first.
80. No visible flicker or focus jump during success/cancel paths.
81. No duplicate UI artifacts after prolonged usage (20+ dictations).

Pass criteria: app feels refined under repeated daily usage.

---

## L. Soak / Stability

82. Run 50 start/stop cycles without crash.
83. Run 20 cycles with frequent app switching during recording.
84. Run 20 cycles with frequent Space switching.
85. Simulate intermittent network failures and recoveries.
86. Verify no runaway CPU usage while idle.
87. Verify no growing temp-file residue over long session.

Pass criteria: stable over time, not just in short demos.

---

## Regression Gate (Quick Pass)

Run these before each release candidate:
- A1, A7, B16, C20, D28, D29, E34, E35, F41, G46, G47, G53, H61, I66, I67, K77

Engineering hygiene checks (same gate, do not skip):
1. `swift build -c release` passes with no newly introduced warnings.
2. Module ownership remains intact (`App` orchestration, `UI` rendering, `Services` integrations, `Core` shared primitives/constants).
3. New user-facing copy is centralized in `AppStrings` unless it is runtime API data and sanitized.
4. New comments explain non-obvious *why* (constraints/tradeoffs), not obvious mechanics.
5. State transitions remain explicit; no hidden side-effect transition paths are introduced.
6. Behavior changes are reflected in both `SPEC.md` and `QA.md`.

If any item fails, block release.
