# GroqDictate Rewrite Plan (First Principles)

## Objective
Re-architect GroqDictate for maintainability, robustness, and predictable UX while preserving the current product feel (menu bar app + floating panel + settings).

## Constraints
- Preserve core UX and panel design direction.
- Keep code minimal and readable.
- Prefer comments only where they explain non-obvious *why*.
- Maintain current feature set while improving reliability.

## Research Inputs
- Apple NSWorkspace activation notifications and frontmost app APIs.
- Apple event monitoring constraints (Accessibility / Secure Input limitations).
- Groq API docs for speech-to-text and error schema.
- Existing SPEC.md and QA.md (new source of truth).

## Architecture Changes
1. Introduce explicit app state machine and error/action mapping.
2. Separate focus concerns:
   - settings return target
   - dynamic dictation target
3. Add `FocusTracker` service based on `NSWorkspace.didActivateApplicationNotification`.
4. Add `HotkeyMonitor` service to isolate event tap / fallback logic.
5. Keep `AudioRecorder` but harden thread-safety for level reads.
6. Improve `GroqAPI` error parsing using structured JSON (`error.message/type/code`).
7. Keep panel visuals, refine processing animation cadence for perceived speed.
8. Simplify comments and remove obvious narration.

## Implementation Steps
1. Refactor `SetupWindow` close/save callbacks (remove embedded focus side-effects).
2. Add `FocusTracker.swift`.
3. Add `HotkeyMonitor.swift`.
4. Rewrite `main.swift` to orchestrate via services and explicit state transitions.
5. Rewrite `GroqAPI.swift` error handling and mapping.
6. Harden `AudioRecorder.swift` level synchronization.
7. Minor cleanup in `FloatingPanel.swift` and labels consistency.
8. Build validation (`swift build -c release`).

## Validation
- Run compile/build.
- Verify behavior against QA regression gate section.

## Deliverable
- Rewritten codebase with improved structure and robustness.
- Behavior aligned with SPEC.md and QA.md.
