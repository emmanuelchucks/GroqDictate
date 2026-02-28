## Summary

This PR implements the macOS standards alignment plan from `MACOS_STANDARDS_AUDIT.md` using a phased approach.

Primary goals:
- remove brittle permission hacks
- make permission behavior explicit and user-guided
- improve reliability for hotkeys and paste automation
- improve temp-file safety and test/CI coverage
- add open-source repo governance docs

## Why these decisions

### 1) Explicit permission orchestration (instead of implicit side effects)
Global hotkeys and synthetic paste are sensitive to TCC state. The previous flow relied on implicit behavior and fallback side effects, which can fail silently across macOS versions.

What we changed:
- introduced `PermissionService` for centralized checks/requests (Mic, Accessibility, ListenEvent, PostEvent)
- removed hidden off-screen permission-anchor window flow
- added explicit user guidance alerts with deep links to relevant System Settings panes

Result:
- clearer permission behavior
- fewer silent failure paths
- easier debugging and future maintenance

### 2) Hotkey reliability under permission constraints
Hotkey startup now reports structured states and handles denied ListenEvent access explicitly.

What we changed:
- `HotkeyMonitor.StartStatus` (`ready`, `listenDenied`, `fallback`, `failed`)
- stricter ListenEvent denied path: skip event tap, use fallback path directly

Result:
- predictable startup behavior
- better operational diagnostics

### 3) Safer audio temp-file lifecycle
Static temp filenames can collide across sessions/retries.

What we changed:
- per-session UUID temp directory/files in `AudioRecorder`
- deterministic cleanup via session-aware teardown

Result:
- reduced collision/race risk
- cleaner retry/cancel lifecycle

### 4) Safer paste automation
Synthetic Cmd+V now checks PostEvent permission first and degrades gracefully.

What we changed:
- PostEvent preflight/request before simulated paste
- clipboard-only fallback notice when event-posting is unavailable

Result:
- robust fallback behavior instead of brittle assumptions

### 5) Better quality gates for open-source release

What we changed:
- added unit tests for deterministic logic (`GroqAPI` mapping/sanitization, permission guidance mapping)
- added GitHub Actions CI (Debug + Release build matrix + tests)
- added OSS governance docs/templates (`CONTRIBUTING`, `CODE_OF_CONDUCT`, `SECURITY`, issue templates, PR template)

Result:
- better regression detection
- better contributor onboarding and triage hygiene

## Key files

### Core implementation
- `Sources/Services/PermissionService.swift`
- `Sources/App/main.swift`
- `Sources/Services/HotkeyMonitor.swift`
- `Sources/Services/AudioRecorder.swift`
- `Sources/Core/AppConstants.swift`
- `Sources/Core/AppStrings.swift`

### Tests + CI
- `Tests/GroqDictateTests/GroqAPIHTTPErrorMappingTests.swift`
- `Tests/GroqDictateTests/GroqAPIErrorMessageParsingTests.swift`
- `.github/workflows/ci.yml`
- `project.yml`
- `GroqDictate.xcodeproj/project.pbxproj`

### OSS governance
- `CONTRIBUTING.md`
- `CODE_OF_CONDUCT.md`
- `SECURITY.md`
- `.github/ISSUE_TEMPLATE/*`
- `.github/pull_request_template.md`

## Validation

Local validation performed:

```bash
xcodebuild -project GroqDictate.xcodeproj -scheme GroqDictate -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

Result: **TEST SUCCEEDED** (12 tests).

## Audit mapping (high-level)

- P0 permission orchestration: ✅ addressed
- P0 hidden permission anchor removal: ✅ addressed
- P0 paste PostEvent gating: ✅ addressed
- P1 temp-file lifecycle hardening: ✅ addressed
- P2 tests/CI: ✅ partially addressed (state-transition tests and static/style checks still pending)
- P2 settings layout modernization: ⏳ not in this PR

## Remaining follow-up (non-blocking for current P0 goals)

1. Add explicit dictation state-transition tests.
2. Add static/style checks to CI.
3. Migrate `SetupWindow` from manual frames to Auto Layout/SwiftUI.
