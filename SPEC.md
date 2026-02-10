# GroqDictate — Behavior Specification

## Overview

GroqDictate turns speech into text with one key. Press Right ⌘ to record, press it again, and the transcription is pasted into whatever app you were using. It should feel like a keyboard shortcut, not an application.

No dock icon, no main window, no app switcher entry. Just a menu bar icon and a floating panel that appears while recording. Users download a single `.app` with zero external dependencies. Latency is the enemy: every millisecond between the key press and the recording starting matters, and every millisecond between stopping and the text appearing matters. When things go wrong, the app tells you what happened and what to do about it. It never leaves you staring at a spinner.

Any proposed change should be measured against this: does it make the core loop faster, more reliable, or less likely to break? If not, it probably doesn't belong here.

---

## 1. First Launch & Onboarding

When a user launches GroqDictate for the first time, there is no API key stored. The app presents the Settings window as onboarding. The menu bar icon (waveform) also appears.

The API key text field is focused and ready for paste. Cmd+V works because the app registers a full Edit menu. LSUIElement apps don't get one by default, so Cut, Copy, Paste, and Select All are wired up explicitly.

The user fills in their Groq API key (validated: non-empty, starts with `gsk_`), chooses a model, microphone, and input gain, then clicks **Done**.

### Closing Without an API Key

If the user closes the Settings window without saving a valid API key (X button, or any other means), the window dismisses and focus returns to whatever app was previously active. The app stays alive in the menu bar. Without a saved API key, the next launch shows the onboarding Settings window again. No permissions are requested because there's nothing to use them for yet.

### Permissions After Onboarding

After a successful save, the app requests permissions in sequence. GroqDictate is an `.accessory` app with no visible windows after Settings closes, so macOS would deactivate it. Background apps can't trigger permission dialogs. To keep the app frontmost during the async permission flow, a tiny invisible anchor window is created.

**Microphone** is requested first. macOS shows the standard "allow microphone access" dialog.

- If **allowed**, the app proceeds to request Accessibility.
- If **denied**, the app proceeds to Accessibility anyway. macOS only shows this dialog once per app install. When the user later tries to record, the panel shows **"⚠ Mic access denied"** and Right ⌘ opens System Settings directly to the Microphone privacy pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`).

**Accessibility** is requested second. macOS opens System Settings to the Accessibility pane. The app installs a CGEvent tap (or falls back to NSEvent monitors until Accessibility is granted). A distributed notification observer watches for the permission change and re-installs the event tap automatically once granted.

- If **granted**, the CGEvent tap installs and the app can consume Esc during recording (preventing it from leaking to the focused app).
- If **denied or ignored**, the app falls back to NSEvent global monitors. Right ⌘ (`flagsChanged`) works without Accessibility in practice. Esc (`keyDown`) does not. So the user can record and transcribe, but cannot cancel with Esc until Accessibility is granted.

  Apple's documentation says global monitors may only monitor "key events" with Accessibility enabled, which technically includes `flagsChanged`. Real-world testing shows `flagsChanged` fires without Accessibility while `keyDown` does not. This is undocumented behavior that could change in a future macOS update.

  Once the user grants Accessibility, the distributed notification observer detects it and upgrades to the CGEvent tap automatically.

The anchor window is released as soon as the permission prompts are triggered. The system-owned dialogs persist independently.

---

## 2. Default Settings

| Setting | Default | Rationale |
|---------|---------|-----------|
| Model | `whisper-large-v3-turbo` | Best balance of speed and accuracy |
| Microphone | System Default | The settings UI does not auto-select any specific device. Only the user knows which input they actually speak into. |
| Input Gain | `5.0x` (maximum) | Captures as much audio as possible out of the box. Users with hot mics can lower it in Settings. |
| Language | `en` (hardcoded) | — |

---

## 3. Recording

### Starting a Recording

When the user presses Right ⌘ and the app is idle:

1. The currently focused app is captured as `targetApp`.
2. The [floating panel](#7-floating-panel) appears at top-center of the screen.
3. Audio recording begins.
4. The waveform animates in sync with voice level.
5. The panel shows **"● Recording"** on the left and **"esc to cancel"** on the right.

The panel is non-activating. It floats above all windows without stealing focus from `targetApp`. The user's cursor stays in their text field, their app stays frontmost.

If microphone access was denied, recording cannot start. The panel shows **"⚠ Mic access denied"** on the left and **"⌘ settings · esc to dismiss"** on the right. Right ⌘ opens System Settings to the Microphone privacy pane. Esc dismisses.

### Cancelling

Pressing Esc at any point during recording or transcription:

1. Stops the recording if active.
2. Cleans up the audio file.
3. Dismisses the panel.
4. Returns focus to `targetApp`.

Esc is consumed by the CGEvent tap and does not reach the focused app. This requires Accessibility. Without it, the NSEvent fallback cannot detect Esc (`keyDown` requires Accessibility). The user must press Right ⌘ again to stop, or wait for it to finish.

If the user presses Esc while a transcription API request is in-flight, the app sets state to idle and dismisses the panel. When the API callback returns, it checks `state == .processing` and silently discards the result. The in-flight URLSession task completes in the background but its result is ignored.

### Stopping & Transcribing

When the user presses Right ⌘ a second time (during recording):

1. Recording stops.
2. The panel switches to **"⟳ Transcribing…"** on the left, **"esc to cancel"** on the right, with a shimmer animation.
3. The audio file is prepared for upload (see [Audio](#9-audio) for format details).
4. The file is uploaded to the Groq API for transcription.

### Transcription Success

1. The panel dismisses.
2. The transcribed text is copied to the system clipboard.
3. The transcribed text is auto-pasted into `targetApp` via simulated Cmd+V.
4. Focus returns to `targetApp`.

### Transcription Failure

If the API request fails, the panel stays visible with an error message. The audio file is preserved on disk for retry. The panel does not auto-dismiss.

What Right ⌘ does depends on the error (see [Error Handling](#4-error-handling) for the full table):

- **Retryable errors** (timeout, rate limit, server issues): re-sends the existing audio file.
- **File too large** (413): starts a new, shorter recording.
- **Invalid API key** (401): opens Settings.

Esc always cleans up the audio file, dismisses the panel, and returns focus to `targetApp`.

---

## 4. Error Handling

The app communicates with the Groq API at `https://api.groq.com/openai/v1/audio/transcriptions`. `timeoutIntervalForRequest` is set to **30 seconds** and `timeoutIntervalForResource` to **60 seconds**. The resource timeout is higher because large audio uploads need more transfer time. The default `timeoutIntervalForResource` of 7 days is explicitly overridden to prevent requests from hanging when the server accepts the connection but stalls on the response.

A pre-warm `HEAD` request is sent at launch to establish the TCP+TLS connection, saving ~100–300ms on the first transcription.

### Error Messages and Actions

| Condition | Top (message) | Bottom Left (action) | Bottom Right | Right ⌘ Action |
|-----------|--------------|---------------------|--------------|----------------|
| Rate limited (429) | ⚠ Rate limited, wait Xs | ⌘ retry | esc to dismiss | Retry transcription |
| Server error (500/502/503) | ⚠ Groq unavailable | ⌘ retry | esc to dismiss | Retry transcription |
| Network timeout | ⚠ Timed out | ⌘ retry | esc to dismiss | Retry transcription |
| Empty transcription | ⚠ No speech detected | ⌘ retry | esc to dismiss | Retry transcription |
| File too large (413) | ⚠ Recording too large | ⌘ new | esc to dismiss | Start new recording |
| Invalid API key (401) | ⚠ Invalid API key | ⌘ settings | esc to dismiss | Open Settings |
| Mic access denied | ⚠ Mic access denied | ⌘ settings | esc to dismiss | Open System Settings > Microphone |
| Other errors | ⚠ (first 50 chars) | | esc to dismiss | — |

For 429 responses, the `retry-after` header from Groq tells us exactly how long to wait. The message includes the wait time.

### Rate Limits (Free Tier)

| Limit | Value |
|-------|-------|
| Requests per minute | 20 |
| Requests per day | 2,000 |
| Audio seconds per hour | 7,200 (2 hours) |
| Audio seconds per day | 28,800 (8 hours) |

---

## 5. Re-launch While Running

### While Idle

When the app is already running and the user launches it again (Raycast, Spotlight, Launchpad, `open -a`, etc.), macOS sends a reopen event. The app opens the Settings window. This is standard for menu bar apps and avoids a "ghost window" problem: macOS briefly activates the app during reopen, and showing a real window gives it something to display.

On close (Done or X), focus returns to the app the user was in before the reopen.

### While Recording or Processing

If the user re-launches during an active recording or transcription, the floating panel is re-ordered to front instead of opening Settings. The active dictation is not disrupted.

macOS activates the app during reopen, making GroqDictate frontmost. Focus returns to `targetApp` when the transcription completes or the user cancels.

### Quit and Cold Relaunch

The user can quit from the menu bar (Quit, or Cmd+Q). On the next launch:

- If an API key exists in Keychain: menu bar icon appears, permissions are verified. Ready.
- If no API key exists: onboarding Settings window appears, same as [first launch](#1-first-launch--onboarding).

---

## 6. Settings

### Opening

Settings can be opened from the menu bar (click waveform icon → "Settings…" or Cmd+,) or by [re-launching the app while idle](#while-idle). The Settings window appears and the app activates.

### Closing

- **Done button**: validates the API key, saves all preferences, closes the window.
- **X button**: closes the window without saving.

Both paths go through a single `windowWillClose` handler that returns focus to the app the user was in before Settings opened and re-installs the event tap (in case Accessibility was granted while Settings was open). Done calls `close()` which triggers `windowWillClose`. X triggers `windowWillClose` directly. No double-firing.

During onboarding, no previous app is captured, so closing Settings keeps the app frontmost for the [permission flow](#permissions-after-onboarding).

---

## 7. Floating Panel

### Properties

- Non-activating (`.nonactivatingPanel`). Never steals focus.
- Floating level. Always on top.
- Joins all Spaces. Visible on every desktop.
- Excluded from Exposé, Cmd+Tab, Cmd+\` (`.transient`, `.ignoresCycle`).
- Excluded from the Windows menu.
- Movable by dragging its background.
- Does not hide on app deactivate.

### Lifecycle

The panel is created once at launch with `defer: false` (pre-created in the window server for instant first show). `show()` positions it at top-center and calls `orderFront`. `dismiss()` resets the view state and calls `orderOut` (hidden but alive for reuse). The panel is never `close()`d. Closing destroys the window server resource and breaks subsequent shows.

### Visual Layout

The panel has two zones. The top zone (most of the panel height) shows the main visual content. The bottom zone is a single row split between a label on the left and an action hint on the right. Esc is always bottom-right.

| State | Top (visual) | Bottom Left | Bottom Right |
|-------|-------------|-------------|--------------|
| Recording | Waveform bars | ● Recording | esc to cancel |
| Transcribing | Shimmer bars | ⟳ Transcribing… | esc to cancel |
| Error (retryable) | ⚠ [error message] | ⌘ retry | esc to dismiss |
| Error (too large) | ⚠ Recording too large | ⌘ new | esc to dismiss |
| Error (bad key) | ⚠ Invalid API key | ⌘ settings | esc to dismiss |
| Mic denied | ⚠ Mic access denied | ⌘ settings | esc to dismiss |
| Error (other) | ⚠ [error message] | | esc to dismiss |

The error message is displayed in the top zone where it has full width. This prevents long messages from clashing with action hints.

---

## 8. Keyboard Behavior

| Key | App State | Action | Consumed? |
|-----|-----------|--------|-----------|
| Right ⌘ | Idle | Start recording | Yes |
| Right ⌘ | Recording | Stop & transcribe | Yes |
| Right ⌘ | Processing | Ignored | Yes |
| Right ⌘ | Error (retryable) | Retry transcription | Yes |
| Right ⌘ | Error (too large) | Start new recording | Yes |
| Right ⌘ | Error (bad key / mic denied) | Open Settings | Yes |
| Esc | Idle | Pass through | No |
| Esc | Recording | Cancel & dismiss, refocus `targetApp` | Yes (CGEvent) / Not available (NSEvent fallback cannot detect `keyDown`) |
| Esc | Processing | Cancel & dismiss, refocus `targetApp` | Yes (CGEvent) / Not available |
| Esc | Error | Clean up & dismiss, refocus `targetApp` | Yes (CGEvent) / Not available |

"Consumed" means the keystroke is intercepted and does not reach the focused app. This requires the CGEvent tap (Accessibility permission). Without Accessibility, the NSEvent fallback can detect Right ⌘ (`flagsChanged`) but not Esc (`keyDown`). Even for Right ⌘, the fallback cannot consume the event. It observes only.

**Secure Input caveat:** When macOS Secure Input is active (password fields, some terminal emulators, 1Password, Bitwarden), CGEvent taps are blocked entirely. Right ⌘ and Esc will not be detected. This is a system-level security measure that cannot be worked around. The user must leave the secure input context before using GroqDictate.

---

## 9. Audio

### Recording Format

Audio is recorded at 16kHz, mono, 16-bit PCM WAV using AudioQueue.

- Whisper downsamples all audio to 16kHz mono internally. Recording at higher sample rates wastes bandwidth with no quality benefit.
- 16-bit depth is a reasonable choice for speech. Higher bit depths increase file size without improving transcription accuracy.
- Groq recommends WAV for lower latency and FLAC for reducing file size.

AudioQueue records directly at the requested format and handles sample rate conversion from the hardware format (typically 44.1kHz or 48kHz) internally. It also handles hardware reconfig on first mic access without intervention. Input gain is applied in the buffer callback by scaling the int16 samples.

### Microphone Selection

When the user selects a specific microphone in Settings, the app sets `kAudioQueueProperty_CurrentDevice` on the AudioQueue before starting it. This property takes a `CFStringRef` device UID (not an `AudioDeviceID`). This only affects GroqDictate's recording, not the system-wide default. Other apps are unaffected. When "System Default" is selected, no property is set and the queue uses whatever macOS has as the current input.

### File Handling

Audio is written to `$TMPDIR/groqdictate.wav` during recording. If the file exceeds 10MB (~5 minutes of speech), it's compressed to `$TMPDIR/groqdictate.flac` via `/usr/bin/afconvert` (ships with every Mac).

The audio file is cleaned up:

- On **transcription success**: no longer needed.
- On **cancel** (Esc): user chose to discard.
- On **dismiss from error** (Esc): user chose not to retry.
- On **starting a new recording**: the old file is overwritten.

The audio file is **preserved** on transcription error, enabling [retry](#transcription-failure).

### File Size Limits

Groq accepts up to 25MB per request on the free tier. At 16kHz mono 16-bit WAV, that's ~13 minutes. With FLAC compression (applied at 10MB+), the practical limit extends to ~25–30 minutes. Recordings exceeding this receive a clear error message.

Chunking (splitting long audio into overlapping segments and concatenating transcriptions) is not implemented. The 25–30 minute limit is more than enough for dictation.

### Silence in Recordings

Long pauses during recording (e.g., the user reads something silently between thoughts) are sent as-is. Whisper handles silence fine. Voice Activity Detection to strip silence would add complexity for negligible benefit in typical dictation.

### Voice Isolation

macOS offers Voice Isolation as a system-wide mic mode in Control Center. Users who want noise suppression can enable it there. It applies to GroqDictate's mic input automatically. The app does not implement its own noise suppression.

---

## 10. Permissions

| Permission | When Requested | If Denied | Re-promptable? |
|------------|---------------|-----------|----------------|
| Microphone | After [onboarding](#permissions-after-onboarding) save | [Actionable error](#starting-a-recording) directing user to System Settings | No. One-time system prompt. Must be enabled manually. |
| Accessibility | After microphone prompt | Esc is unavailable (cannot cancel recording). Core functionality (Right ⌘) still works via [NSEvent fallback](#cancelling). Auto-detected when granted later. | No. One-time system prompt. Must be enabled manually. |

---

## 11. Menu Bar

The status bar icon is a system waveform symbol. The menu contains:

- "Right ⌘ — start / stop" (informational)
- "Esc — cancel" (informational)
- Separator
- "Settings…" (Cmd+,)
- Separator
- "Quit GroqDictate" (Cmd+Q)

---

## 12. Technical Notes

### Activation Policy

The app runs as `.accessory` (LSUIElement): no dock icon, no app switcher entry. macOS deactivates `.accessory` apps when they have no visible windows. The invisible anchor window (see [Permissions After Onboarding](#permissions-after-onboarding)) handles the permission flow. The non-activating floating panel handles recording without requiring activation.

### Event Tap vs NSEvent Monitors

The CGEvent tap (requires Accessibility) intercepts and consumes keyboard events system-wide. NSEvent global monitors can observe but not consume. They also have a further limitation: `keyDown` events (Esc) require Accessibility, while `flagsChanged` events (Right ⌘) work without it in practice. Apple's documentation says all "key events" require Accessibility, so the `flagsChanged` behavior is undocumented and could change.

The app tries the CGEvent tap first. If Accessibility isn't granted, it falls back to NSEvent monitors. A distributed notification observer watches for the permission change and upgrades to the tap when granted. Without this fallback, the app would be unusable until Accessibility is granted. The tradeoff: the user can record and transcribe but cannot cancel with Esc.

### Connection Warmup and Retry

On launch (when an API key exists), a `HEAD` request is sent to `api.groq.com` to pre-establish the TCP+TLS connection. The first transcription reuses this warm connection, saving ~100-300ms.

QUIC connections go stale after idle periods. If the user records a few minutes after launch, the warm connection may be dead. The shared URLSession will try to reuse it, fail to write the request body, and wait for the full timeout before reporting an error.

To handle this: if a request fails with a timeout, connection lost, or secure connection error, retry once with a fresh ephemeral URLSession. Reset the shared session afterward to drop any remaining dead connections. This adds at most one extra round-trip on stale connections and avoids surfacing timeout errors for a problem the user cannot control.
