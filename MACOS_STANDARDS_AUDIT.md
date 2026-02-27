# GroqDictate macOS Standards Audit (2026-02-27)

Comprehensive audit of current project implementation against modern macOS app development standards and Apple best practices (menu bar app architecture, TCC permissions, event monitoring, distribution security/notarization, AppKit patterns, and operational robustness).

---

## Scope reviewed

- Build/distribution: `Makefile`, `project.yml`, `GroqDictate.xcodeproj/project.pbxproj`
- App config/security: `GroqDictate/Info.plist`, `GroqDictate/GroqDictate.entitlements`
- Source:
  - `Sources/App/main.swift`
  - `Sources/Core/*`
  - `Sources/Services/*`
  - `Sources/UI/*`
- Product docs: `README.md`, `SPEC.md`, `QA.md`

---

## Current standards baseline (2025–2026)

For a menu bar dictation utility with global hotkey + paste automation, current best practice is:

1. **Menu bar architecture**
   - `LSUIElement` / accessory app is valid.
   - Use `NSStatusItem`/`NSStatusBar` (or `MenuBarExtra` when SwiftUI-first and OS target allows).

2. **Startup/login**
   - Use `SMAppService` for launch-at-login.

3. **TCC permissions**
   - Microphone via AVFoundation request flow.
   - For keyboard event listening, use explicit Input Monitoring APIs (`CGPreflightListenEventAccess`, `CGRequestListenEventAccess`) instead of relying only on Accessibility side effects.
   - For synthetic event posting, account for PostEvent/Accessibility consent behavior.

4. **Security/distribution**
   - Developer ID signing + Hardened Runtime + notarization for non–Mac App Store distribution.
   - Secure timestamp enabled.
   - Avoid brittle `--deep` signing workflows.

5. **Data/security hygiene**
   - Keychain for credentials.
   - Unique temp files per session.

6. **HIG/UX**
   - Menu bar apps should avoid fragile hidden-window tricks.
   - Error states should be actionable.

---

## What is already standard/solid

- ✅ Correct menu bar app model (`LSUIElement` + accessory activation policy).
- ✅ Uses `SMAppService.mainApp` for launch at login (modern).
- ✅ Uses Keychain for API key storage.
- ✅ Strong module boundaries (`App`, `Core`, `Services`, `UI`).
- ✅ Good error taxonomy and user-facing error simplification.
- ✅ Strong behavior spec + QA checklist coverage.

---

## Non-standard / hacky / workaround-heavy findings

## A) Permissions + event capture (highest risk)

1. **Hidden off-screen permission anchor window**
   - File: `Sources/App/main.swift` (`startPermissionFlow`)
   - Pattern: creates 1x1 borderless window at negative coordinates.
   - Risk: UI side-effect trick; brittle across macOS updates.

2. **Accessibility distributed-notification hook**
   - File: `Sources/App/main.swift` (`requestAccessibilityThenStart`)
   - Pattern: observes `com.apple.accessibility.api`.
   - Risk: implementation-coupled behavior, not robust capability-state orchestration.

3. **No explicit Input Monitoring preflight/request path**
   - File: `Sources/Services/HotkeyMonitor.swift`
   - Pattern: install event tap directly, then fallback.
   - Risk: ambiguous permission UX and inconsistent behavior in secure-input contexts.

4. **NSEvent global/local fallback for key capture**
   - File: `Sources/Services/HotkeyMonitor.swift`
   - Risk: known limitations for reliable global interception.

## B) Paste automation + focus manipulation (high risk)

5. **Synthetic Cmd+V event injection**
   - File: `Sources/App/main.swift` (`simulatePaste`)
   - Pattern: posts CGEvents for key down/up.
   - Risk: fragile under Secure Input, TCC state, app-specific event handling.

6. **AX heuristic to infer pasteability**
   - File: `Sources/Services/PasteTargetInspector.swift`
   - Pattern: role/settable-attribute checks.
   - Risk: app/webview variability; best-effort only.

## C) Build/sign/distribution (high risk)

7. **`codesign --deep` usage**
   - File: `Makefile` (`install`)
   - Risk: brittle and non-deterministic for complex signing trees.

8. **`--timestamp=none` when signing**
   - File: `Makefile` (`install`)
   - Risk: not aligned with modern notarized distribution expectations.

9. **No notarization/stapling pipeline**
   - Files: `Makefile`, docs
   - Risk: incomplete modern outside-MAS distribution readiness.

10. **Empty entitlements file**
    - File: `GroqDictate/GroqDictate.entitlements`
    - Note: acceptable for non-sandbox distribution, but weak least-privilege posture and poor MAS readiness.

## D) Runtime/audio implementation workarounds (medium risk)

11. **Fixed temp filenames**
    - File: `Sources/Services/AudioRecorder.swift`
    - Pattern: static `groqdictate.wav` / `groqdictate.flac` in temp.
    - Risk: collisions/races across sessions or multiple instances.

12. **Hand-rolled WAV + trimming heuristics**
    - File: `Sources/Services/AudioRecorder.swift`
    - Risk: edge-case brittleness by mic/environment/accent.

13. **External `afconvert` subprocess for FLAC**
    - File: `Sources/Services/AudioRecorder.swift`
    - Risk: dependency on tool availability/process behavior; harder deterministic testing.

## E) Networking/response logic (medium risk)

14. **Manual multipart and JSON parsing**
    - File: `Sources/Services/GroqAPI.swift`
    - Risk: drift risk with API changes.

15. **Custom transcript segment-drop heuristic**
    - File: `Sources/Services/GroqAPI.swift` (`extractTranscription`)
    - Pattern: drops segment by gap + compression ratio.
    - Risk: can suppress valid speech content unexpectedly.

16. **Ad hoc retry implementation**
    - File: `Sources/Services/GroqAPI.swift`
    - Pattern: reset + ephemeral retry.
    - Risk: less predictable than policy-driven backoff/telemetry strategy.

## F) UI/UX implementation shortcuts (low-medium)

17. **Manual frame-based settings layout**
    - File: `Sources/UI/SetupWindow.swift`
    - Risk: weaker adaptivity/localization/future-proofing vs Auto Layout/SwiftUI layout.

18. **Manual main Edit menu wiring in accessory app**
    - File: `Sources/App/main.swift` (`buildAppMenu`)
    - Risk: workaround for command routing edge cases.

19. **Hardcoded System Settings deep links**
    - File: `Sources/Core/AppConstants.swift`
    - Risk: pane URI format can shift across macOS versions.

## G) Operational/dev workflow oddities (low)

20. **`pkill` + `sleep` for process sequencing**
    - File: `Makefile`
    - Risk: race-prone local workflow behavior.

21. **Build-time generated icon script**
    - Files: `generate-icon.swift`, `Makefile`
    - Risk: atypical vs asset-catalog-centric workflow.

22. **No test target / no CI evidence in repo**
    - Risk: fragile regression detection for global-input/focus-sensitive app behavior.

---

## Priority remediation roadmap

## P0 (first)

1. Add explicit Input Monitoring permission orchestration (`CGPreflightListenEventAccess` / `CGRequestListenEventAccess`) and clearer denied-state UX.
2. Replace signing flow with modern Developer ID + Hardened Runtime + secure timestamp + notarization + stapling.
3. Remove/replace hidden off-screen permission anchor approach.

## P1

4. Harden paste strategy (reduce dependence on synthetic Cmd+V as primary action; keep robust fallback modes).
5. Move temp audio files to unique per-session names and enforce lifecycle cleanup invariants.
6. Improve retry policy to explicit backoff classes and richer diagnostics.

## P2

7. Modernize settings UI layout to Auto Layout/SwiftUI.
8. Replace brittle deep links with resilient permission guidance UX.
9. Add tests and CI checks for state transitions, permission states, and error mappings.

---

## Practical sequencing (one-by-one fix plan)

1. **Permissions stack** (Input Monitoring + Accessibility + microphone flow cleanup)
2. **Distribution security stack** (codesign/notary pipeline)
3. **Paste reliability stack** (capability detection + fallback modes)
4. **Audio temp-file and lifecycle stack**
5. **Networking/retry policy stack**
6. **UI modernizations**
7. **Test + CI hardening**

---

## Notes

- This file is intended as a working remediation checklist to address findings one-by-one.
- Keep this audit updated as each item is completed to prevent regressions.
