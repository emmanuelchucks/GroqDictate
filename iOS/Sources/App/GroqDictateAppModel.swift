import AVFoundation
import CallKit
import Foundation
import UIKit
import UserNotifications

@MainActor
final class GroqDictateAppModel: ObservableObject {
    static let shared = GroqDictateAppModel()
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lifecycle: RecordingLifecycle = .idle
    @Published private(set) var apiKey: String
    @Published private(set) var spellingFixesText: String
    @Published private(set) var spellingFixes: SpellingFixes
    @Published private(set) var stoppedSessionID: UUID?
    @Published private(set) var copiedSessionID: UUID?
    @Published private(set) var slowSessionID: UUID?
    @Published private var clipboardCopy: ClipboardCopy?
    @Published var errorMessage: String?

    private let store: SessionStore
    private let capture = AudioCaptureService()
    private let client = GroqIOSClient()
    private let keychain = IOSKeychainStore()
    private let callObserver = CXCallObserver()
    private lazy var processing = SerialRunner<UUID> { [unowned self] sessionID in
        await performProcessing(sessionID: sessionID)
    }
    private var activeSegmentID: UUID?
    private var rotationTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var interruptionFinalizationTask: Task<Void, Never>?
    private var stopUptimes: [UUID: TimeInterval] = [:]
    private var uncopiedSessionID: UUID?
    private var hasRestored = false
    private var isRestoring = false
    private let segmentDuration: Duration = .seconds(5 * 60)
    private static let spellingFixesDefaultsKey = "spelling-fixes"

    init() {
        do {
            store = try SessionStore()
        } catch {
            fatalError("Could not create recording store: \(error)")
        }
        apiKey = keychain.loadAPIKey()
        let fixesText = UserDefaults.standard.string(forKey: Self.spellingFixesDefaultsKey) ?? ""
        spellingFixesText = fixesText
        spellingFixes = SpellingFixes(fixesText)
        capture.onInterruption = { [weak self] event in
            self?.handleInterruption(event)
        }
    }

    var currentSession: RecordingSession? { sessions.first { $0.id == currentSessionID } }
    var stoppedSession: RecordingSession? { stoppedSessionID.flatMap(session(id:)) }

    func session(id: UUID) -> RecordingSession? {
        sessions.first { $0.id == id }
    }

    func audioURL(sessionID: UUID, fileName: String) -> URL {
        store.audioURL(sessionID: sessionID, fileName: fileName)
    }

    func hasAudio(sessionID: UUID, fileName: String) async -> Bool {
        await store.hasAudio(sessionID: sessionID, fileName: fileName)
    }

    func toggleRecording() {
        switch lifecycle.requestToggle() {
        case .start:
            Task { await startSession() }
        case .stop:
            Task { await stopSession() }
        case nil:
            break
        }
    }

    func saveSettings(apiKey: String, spellingFixes: String) -> String? {
        do {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedKey != self.apiKey {
                try keychain.saveAPIKey(normalizedKey)
            }
            let fixesText = spellingFixes.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(fixesText, forKey: Self.spellingFixesDefaultsKey)
            self.apiKey = normalizedKey
            spellingFixesText = fixesText
            self.spellingFixes = SpellingFixes(fixesText)
            retryAll()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Failed parts become pending again only on a retry, so a run that is
    /// already going doesn't re-upload a part that just failed.
    func retry(_ sessionID: UUID) {
        Task {
            if let session = try? await store.update(sessionID, { session in
                for index in session.segments.indices where session.segments[index].state == .failed {
                    session.segments[index].state = .pending
                }
            }) {
                replace(session)
            }
            await process(sessionID: sessionID)
        }
    }

    func canRetry(_ session: RecordingSession) -> Bool {
        session.pendingCount > 0 && session.id != currentSessionID && !processing.isRunning(session.id)
    }

    func retryAll() {
        for session in sessions where canRetry(session) {
            retry(session.id)
        }
    }

    /// The transcript as shown and copied. Fixes apply here rather than when
    /// stored, so editing the list fixes older recordings too.
    func text(of session: RecordingSession) -> String {
        spellingFixes.apply(to: session.transcript)
    }

    func copyTranscript(_ session: RecordingSession) {
        UIPasteboard.general.string = text(of: session)
        clipboardCopy = ClipboardCopy(sessionID: session.id, changeCount: UIPasteboard.general.changeCount)
    }

    /// Groq's text before cleaning, for recovering a wrong removal.
    func copyOriginalTranscript(_ session: RecordingSession) {
        guard let original = session.originalTranscript else { return }
        UIPasteboard.general.string = original
        clipboardCopy = nil
    }

    /// True until anything else is copied; the change count says so without
    /// reading the pasteboard.
    func isOnClipboard(_ sessionID: UUID) -> Bool {
        clipboardCopy?.sessionID == sessionID && clipboardCopy?.changeCount == UIPasteboard.general.changeCount
    }

    func canDelete(_ session: RecordingSession) -> Bool {
        session.id != currentSessionID && !processing.isRunning(session.id)
    }

    func delete(_ sessionID: UUID) async {
        guard let session = session(id: sessionID), canDelete(session) else { return }
        do {
            try await store.delete(sessionID)
            sessions.removeAll { $0.id == sessionID }
            if stoppedSessionID == sessionID { stoppedSessionID = nil }
        } catch {
            errorMessage = "Couldn't delete the recording"
        }
    }

    /// The one way into `.resuming`: the Resume button, iOS's
    /// interruption-ended notice and returning to the app all come here.
    func resume(reportsFailure: Bool = true) {
        guard currentSessionID != nil, lifecycle.beginResume() else { return }
        Task { await resumeInterruptedSession(reportsFailure: reportsFailure) }
    }

    /// iOS often sends no interruption-ended notice (alarms, timers), so
    /// coming back to the app resumes too, but not during a call, which
    /// keeps the mic; there the Resume button stays.
    func resumeAfterReturningToApp() {
        guard callObserver.calls.isEmpty else { return }
        resume(reportsFailure: false)
    }

    /// Finishes a copy iOS refused while the app was in the background.
    func copyTranscriptRefusedInBackground() {
        guard let sessionID = uncopiedSessionID, let session = session(id: sessionID) else { return }
        uncopiedSessionID = nil
        copyTranscriptAutomaticallyIfComplete(session)
    }

    func prepareForVisibleApp() async {
        guard UIApplication.shared.applicationState == .active else { return }
        await prepare()
    }

    func appDidEnterBackground() {
        if stoppedSession?.state != .processing {
            stoppedSessionID = nil
            copiedSessionID = nil
        }
    }

    private func prepare() async {
        while isRestoring {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !hasRestored else { return }
        isRestoring = true
        defer { isRestoring = false }

        TimingDiagnostics.shared.record(.restorationStarted)
        await restore()
        hasRestored = true
        TimingDiagnostics.shared.record(.restorationFinished)
    }

    private func restore() async {
        do {
            sessions = capture.isRecording
                ? try await store.loadAll()
                : try await store.recoverInterruptedSessions()
            if !apiKey.isEmpty { retryAll() }
        } catch {
            errorMessage = "Saved recordings could not be loaded"
        }
    }

    private func startSession(requestPermission: Bool = true) async {
        stoppedSessionID = nil
        copiedSessionID = nil
        uncopiedSessionID = nil
        // Asked here, while the user is looking at the app, without holding
        // up the recording; the transcript-ready notification is what tells
        // them the text is ready after they leave.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        let granted = requestPermission
            ? await capture.requestPermission()
            : AVAudioApplication.shared.recordPermission == .granted
        guard granted else {
            lifecycle = .idle
            errorMessage = IOSAppStrings.Errors.micDenied
            return
        }

        var createdID: UUID?
        do {
            let created = try await store.createSession()
            createdID = created.id
            let session = try await startSegment(sessionID: created.id, stateIfRefused: .failed)
            currentSessionID = session.id
            lifecycle = .recording
            TimingDiagnostics.shared.record(.recordingStarted, sessionID: session.id)
            replace(session)
            startElapsedAndRotation()
        } catch {
            TimingDiagnostics.shared.record(.recordingStartFailed, sessionID: createdID, code: Self.diagnosticCode(error))
            // A session that never recorded has nothing to keep.
            if let createdID {
                try? await store.delete(createdID)
                sessions.removeAll { $0.id == createdID }
            }
            currentSessionID = nil
            lifecycle = .idle
            errorMessage = error.localizedDescription
        }
    }

    /// Reserves the next segment durably, then starts the recorder into it.
    /// If the recorder refuses, the reservation is removed again.
    private func startSegment(
        sessionID: UUID,
        stateIfRefused: RecordingSession.State
    ) async throws -> RecordingSession {
        let reserved = try await store.update(sessionID) { session in
            let next = RecordingSession.Segment.next(in: session)
            session.segments.append(next)
            session.state = .recording
        }
        guard let segment = reserved.segments.last else { throw AudioCaptureService.CaptureError.couldNotStart }
        do {
            try capture.start(fileURL: store.audioURL(sessionID: sessionID, fileName: segment.fileName))
        } catch {
            if let restored = try? await store.update(sessionID, { session in
                session.segments.removeAll { $0.id == segment.id }
                session.state = stateIfRefused
            }) {
                replace(restored)
            }
            throw error
        }
        activeSegmentID = segment.id
        errorMessage = nil
        return reserved
    }

    private func stopSession() async {
        lifecycle = .stopping
        let pendingRotation = rotationTask
        pendingRotation?.cancel()
        rotationTask = nil
        elapsedTask?.cancel()
        if let pendingRotation {
            await pendingRotation.value
        }
        if let interruptionFinalizationTask {
            await interruptionFinalizationTask.value
            self.interruptionFinalizationTask = nil
        }
        guard let sessionID = currentSessionID else {
            lifecycle = .idle
            return
        }
        capture.stop()
        TimingDiagnostics.shared.record(.recordingStopped, sessionID: sessionID)
        stopUptimes[sessionID] = ProcessInfo.processInfo.systemUptime
        stoppedSessionID = sessionID
        markSlowIfStillProcessing(sessionID)
        await endActiveSegment(sessionID: sessionID, sessionState: .processing)
        currentSessionID = nil
        elapsed = 0
        lifecycle = .idle
        await process(sessionID: sessionID)
    }

    private func rotateSegment() async {
        guard lifecycle == .recording,
              let sessionID = currentSessionID,
              let previousSegmentID = activeSegmentID,
              capture.isRecording
        else { return }

        do {
            // Reserve the next segment durably while the current recorder is
            // still active. No storage await occurs during the recorder swap.
            let reserved = try await store.update(sessionID) { session in
                let next = RecordingSession.Segment.next(in: session)
                session.segments.append(next)
            }
            guard let nextSegment = reserved.segments.last else { return }
            let removeReservation: @Sendable (inout RecordingSession) -> Void = { session in
                session.segments.removeAll { $0.id == nextSegment.id }
            }
            guard lifecycle == .recording,
                  currentSessionID == sessionID,
                  activeSegmentID == previousSegmentID,
                  capture.isRecording,
                  !Task.isCancelled
            else {
                replace(try await store.update(sessionID, removeReservation))
                return
            }

            let previousUsedBluetooth = capture.takePartUsedBluetooth()
            do {
                try capture.rotate(fileURL: store.audioURL(sessionID: sessionID, fileName: nextSegment.fileName))
            } catch {
                if capture.isRecording {
                    // Preparation failed before the current recorder stopped.
                    // Roll back only the empty reservation and keep recording.
                    replace(try await store.update(sessionID, removeReservation))
                    return
                }

                let endedAt = Date()
                currentSessionID = nil
                activeSegmentID = nil
                lifecycle = .idle
                capture.stop()
                elapsedTask?.cancel()
                let failed = try? await store.update(sessionID) { session in
                    if let index = session.segments.firstIndex(where: { $0.id == previousSegmentID }) {
                        session.segments[index].endedAt = endedAt
                        session.segments[index].state = .pending
                        session.segments[index].bluetoothInput = previousUsedBluetooth
                    }
                    if let index = session.segments.firstIndex(where: { $0.id == nextSegment.id }) {
                        session.segments[index].endedAt = endedAt
                        session.segments[index].state = .unavailable
                        session.segments[index].lastError = "This segment was not recorded"
                    }
                    session.state = .processing
                }
                if let failed { replace(failed) }
                errorMessage = IOSAppStrings.Errors.micStopped
                stoppedSessionID = sessionID
                await process(sessionID: sessionID)
                return
            }

            let rotatedAt = Date()
            activeSegmentID = nextSegment.id
            replace(try await store.update(sessionID) { session in
                guard let index = session.segments.firstIndex(where: { $0.id == previousSegmentID }) else { return }
                session.segments[index].endedAt = rotatedAt
                session.segments[index].state = .pending
                session.segments[index].bluetoothInput = previousUsedBluetooth
                session.segments[index].lastError = nil
            })
            // The finished part is transcribed while the next one records, so
            // only the last part is left at Stop.
            if !apiKey.isEmpty { Task { await process(sessionID: sessionID) } }
        } catch {
            // A persistence failure must not tear down a recorder that is still
            // safely capturing audio, or a pause the interruption path now owns.
            if !capture.isRecording, lifecycle == .recording {
                currentSessionID = nil
                activeSegmentID = nil
                lifecycle = .idle
                errorMessage = IOSAppStrings.Errors.micStopped
            }
        }
    }

    private func endActiveSegment(sessionID: UUID, sessionState: RecordingSession.State) async {
        let segmentID = activeSegmentID
        activeSegmentID = nil
        let endedAt = Date()
        let usedBluetooth = capture.takePartUsedBluetooth()
        guard let session = try? await store.update(sessionID, { session in
            if let segmentID, let index = session.segments.firstIndex(where: { $0.id == segmentID }) {
                session.segments[index].endedAt = endedAt
                session.segments[index].bluetoothInput = usedBluetooth
                session.segments[index].state = .pending
                session.segments[index].lastError = nil
            }
            // A part that failed while recording continued gets another try
            // in the pass that runs at Stop.
            if sessionState == .processing {
                for index in session.segments.indices where session.segments[index].state == .failed {
                    session.segments[index].state = .pending
                }
            }
            session.state = sessionState
        }) else { return }
        replace(session)
    }

    private func handleInterruption(_ event: AudioCaptureService.InterruptionEvent) {
        switch event {
        case .began, .routeLost:
            guard lifecycle == .recording, let sessionID = currentSessionID else { return }
            lifecycle = .interrupted
            TimingDiagnostics.shared.record(event == .routeLost ? .routeLost : .interruptionBegan, sessionID: sessionID)
            let pendingRotation = rotationTask
            pendingRotation?.cancel()
            rotationTask = nil
            elapsedTask?.cancel()
            interruptionFinalizationTask = Task { [weak self] in
                if let pendingRotation {
                    await pendingRotation.value
                }
                guard let self,
                      lifecycle == .interrupted || lifecycle == .resuming,
                      currentSessionID == sessionID
                else { return }
                await endActiveSegment(sessionID: sessionID, sessionState: .interrupted)
                elapsed = currentSession?.duration ?? elapsed
            }
        case .ended(let shouldResume):
            guard lifecycle == .interrupted else { return }
            TimingDiagnostics.shared.record(.interruptionEnded, sessionID: currentSessionID, code: shouldResume ? 1 : 0)
            if shouldResume { resume() }
        }
    }

    private func resumeInterruptedSession(reportsFailure: Bool) async {
        if let interruptionFinalizationTask {
            await interruptionFinalizationTask.value
            self.interruptionFinalizationTask = nil
        }
        guard lifecycle == .resuming, let sessionID = currentSessionID else { return }
        do {
            let session = try await startSegment(sessionID: sessionID, stateIfRefused: .interrupted)
            lifecycle = .recording
            TimingDiagnostics.shared.record(.recordingResumed, sessionID: sessionID)
            replace(session)
            startElapsedAndRotation()
        } catch {
            TimingDiagnostics.shared.record(.resumeFailed, sessionID: sessionID, code: Self.diagnosticCode(error))
            lifecycle = .interrupted
            guard reportsFailure else { return }
            errorMessage = (error as? AudioCaptureService.CaptureError)?.isMicrophoneBusy == true
                ? IOSAppStrings.Recording.resumeMicBusy
                : IOSAppStrings.Recording.resumeFailed
        }
    }

    private func startElapsedAndRotation() {
        rotationTask?.cancel()
        elapsedTask?.cancel()
        let segmentDuration = self.segmentDuration
        rotationTask = Task { [weak self] in
            try? await Task.sleep(for: segmentDuration)
            guard !Task.isCancelled else { return }
            await self?.rotateSegment()
            guard let self,
                  !Task.isCancelled,
                  lifecycle == .recording,
                  currentSessionID != nil,
                  capture.isRecording
            else { return }
            startElapsedAndRotation()
        }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                elapsed = currentSession?.duration ?? 0
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks iOS for time to finish, since the usual next step after Stop is
    /// leaving the app to paste.
    private func process(sessionID: UUID) async {
        let backgroundTask = BackgroundTask(name: "Transcription")
        await processing.run(sessionID)
        backgroundTask.end()
    }

    private func performProcessing(sessionID: UUID) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if currentSessionID != sessionID,
               let session = try? await store.update(sessionID, { $0.state = .failed }) {
                replace(session)
            }
            errorMessage = IOSAppStrings.Transcription.pendingKey
            return
        }

        do {
            // Each round claims the earliest pending part from the latest saved
            // state, so a part that becomes pending mid-pass (rollover, Stop)
            // is picked up in the same pass.
            var rateLimited = false
            while !rateLimited {
                let isLive = currentSessionID == sessionID
                let claimed = try await store.update(sessionID) { session in
                    guard let index = session.segments.indices
                        .filter({ session.segments[$0].state == .pending })
                        .min(by: { session.segments[$0].index < session.segments[$1].index })
                    else { return }
                    session.segments[index].state = .transcribing
                    session.segments[index].lastError = nil
                    if !isLive { session.state = .processing }
                }
                replace(claimed)
                guard let segment = claimed.segments.first(where: { $0.state == .transcribing }) else { break }
                let segmentID = segment.id
                let prompt = TranscriptionPrompt.make(
                    previousText: claimed.segments.first { $0.index == segment.index - 1 }?.transcript
                )

                var text: String?
                var rawText: String?
                var failure: String?
                var unreadable = false
                do {
                    let audioURL = store.audioURL(sessionID: sessionID, fileName: segment.fileName)
                    let result = try await client.transcribe(
                        fileURL: audioURL,
                        apiKey: apiKey,
                        prompt: prompt,
                        sessionID: sessionID
                    )
                    rawText = result.text
                    text = await TranscriptCleanup.cleaned(
                        result,
                        prompt: prompt,
                        hasSpeech: { ranges in
                            let started = ProcessInfo.processInfo.systemUptime
                            let speech = await SpeechCheck.speech(
                                in: ranges, fileURL: audioURL,
                                threshold: segment.bluetoothInput == false ? SpeechCheck.widebandMicThreshold : SpeechCheck.threshold
                            )
                            // code: segments with no voice under them, or -1 when the audio couldn't be read.
                            TimingDiagnostics.shared.record(
                                .speechChecked, sessionID: sessionID,
                                elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                code: speech.map { $0.filter { !$0 }.count } ?? -1
                            )
                            return speech
                        },
                        retranscribe: { [client, apiKey] range in
                            guard let clip = await AudioClip.m4a(from: audioURL, range: range) else { return nil }
                            defer { try? FileManager.default.removeItem(at: clip) }
                            return try? await client.transcribe(fileURL: clip, apiKey: apiKey, sessionID: sessionID).text
                        }
                    )
                } catch {
                    failure = error.localizedDescription
                    if case GroqIOSClient.ClientError.rateLimited = error { rateLimited = true }
                    if case GroqIOSClient.ClientError.unreadableAudio = error { unreadable = true }
                }
                let finishedText = text
                let finishedRawText = rawText
                let finishedFailure = failure
                let isUnreadable = unreadable
                replace(try await store.update(sessionID) { session in
                    guard let index = session.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                    if let finishedText {
                        session.segments[index].transcript = finishedText
                        session.segments[index].rawTranscript = finishedRawText
                        session.segments[index].state = .complete
                    } else if isUnreadable {
                        // Retrying can't help a file Groq can't decode.
                        session.segments[index].state = .unavailable
                        session.segments[index].lastError = finishedFailure
                    } else {
                        session.segments[index].state = .failed
                        session.segments[index].lastError = finishedFailure
                    }
                    session.transcript = session.assembledTranscript
                })
                // The remaining parts would hit the same limit; they stay pending.
            }

            // The recorder owns the state of the session it is recording.
            let isLive = currentSessionID == sessionID
            let stoppedByRateLimit = rateLimited
            let finished = try await store.update(sessionID) { session in
                guard !isLive else { return }
                // Parts still pending after a full pass became pending after its
                // last claim (Stop during a live pass), and the pass Stop asked
                // for will take them; only a rate limit leaves them waiting.
                let pending = session.segments.contains { $0.state == .pending }
                session.state = pending ? (stoppedByRateLimit ? .failed : .processing) : session.finishedState
            }
            replace(finished)
            // Only the recording just stopped goes to the clipboard; a retried
            // older one finishing later mustn't replace it.
            if !isLive, sessionID == stoppedSessionID {
                copyTranscriptAutomaticallyIfComplete(finished)
                if finished.state == .complete, finished.transcript.isEmpty { returnCardToIdle(after: sessionID) }
            }
        } catch SessionStore.StoreError.sessionNotFound {
            // Deleted while queued.
        } catch {
            errorMessage = IOSAppStrings.Transcription.audioSafe
        }
    }

    nonisolated static func automaticClipboardText(for session: RecordingSession, fixes: SpellingFixes) -> String? {
        guard session.state == .complete,
              !session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return fixes.apply(to: session.transcript)
    }

    /// The usual flow is Stop, then switch to the app to paste into, so this
    /// often runs in the background. There an app's haptics don't play, so a
    /// notification (sound or vibration, plus a banner) says the text is ready.
    /// iOS may refuse a background pasteboard write; the change count shows
    /// whether it took, and if not, the copy happens when the app comes back.
    private func copyTranscriptAutomaticallyIfComplete(_ session: RecordingSession) {
        guard let transcript = Self.automaticClipboardText(for: session, fixes: spellingFixes) else { return }
        let pasteboard = UIPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        pasteboard.string = transcript
        let copied = pasteboard.changeCount != previousChangeCount
        let isActive = UIApplication.shared.applicationState == .active
        if copied {
            copiedSessionID = session.id
            clipboardCopy = ClipboardCopy(sessionID: session.id, changeCount: pasteboard.changeCount)
            returnCardToIdle(after: session.id)
        } else {
            uncopiedSessionID = session.id
        }
        TimingDiagnostics.shared.record(
            .transcriptReady,
            sessionID: session.id,
            elapsedSeconds: stopUptimes.removeValue(forKey: session.id)
                .map { ProcessInfo.processInfo.systemUptime - $0 },
            code: (copied ? 1 : 0) + (isActive ? 0 : 10),
            audioSeconds: session.duration
        )
        if isActive {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            Self.postTranscriptReadyNotification(transcript: transcript, copied: copied)
        }
    }

    /// Uploads usually finish in one to three seconds (timing log, 8–10 Nov),
    /// so only a wait past that is worth showing.
    private func markSlowIfStillProcessing(_ sessionID: UUID) {
        slowSessionID = nil
        Task {
            try? await Task.sleep(for: .seconds(4))
            if stoppedSessionID == sessionID, session(id: sessionID)?.state == .processing {
                slowSessionID = sessionID
            }
        }
    }

    /// Results show on the card briefly; the list row keeps the record.
    private func returnCardToIdle(after sessionID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard stoppedSessionID == sessionID, lifecycle == .idle else { return }
            stoppedSessionID = nil
            copiedSessionID = nil
        }
    }

    private static func postTranscriptReadyNotification(transcript: String, copied: Bool) {
        let content = UNMutableNotificationContent()
        content.title = copied ? IOSAppStrings.Recording.copied : IOSAppStrings.Transcription.readyTapToCopy
        content.body = String(transcript.prefix(120))
        content.sound = .default
        let center = UNUserNotificationCenter.current()
        // One identifier, so a new notice replaces the last; and it removes
        // itself once the banner has shown, so nothing is left to clear.
        center.add(UNNotificationRequest(identifier: transcriptNotificationID, content: content, trigger: nil))
        Task { @MainActor in
            let backgroundTask = BackgroundTask(name: "Clear transcript notice")
            try? await Task.sleep(for: .seconds(6))
            center.removeDeliveredNotifications(withIdentifiers: [transcriptNotificationID])
            backgroundTask.end()
        }
    }

    static let transcriptNotificationID = "transcript-ready"

    func clearTranscriptNotifications() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.transcriptNotificationID])
    }

    /// Store updates can arrive out of order; the newer saved copy wins.
    private func replace(_ session: RecordingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            guard session.updatedAt >= sessions[index].updatedAt else { return }
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.createdAt > $1.createdAt }
    }

    private static func diagnosticCode(_ error: Error) -> Int {
        (error as? AudioCaptureService.CaptureError)?.code ?? (error as NSError).code
    }
}

private struct ClipboardCopy {
    let sessionID: UUID
    let changeCount: Int
}

@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
