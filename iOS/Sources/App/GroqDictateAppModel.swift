import AVFoundation
import Foundation
import UIKit

@MainActor
final class GroqDictateAppModel: ObservableObject {
    static let shared = GroqDictateAppModel()
    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lifecycle: RecordingLifecycle = .idle
    @Published private(set) var apiKey: String
    @Published private(set) var vocabularyHints: String
    @Published var errorMessage: String?

    private let store: SessionStore
    private let capture = AudioCaptureService()
    private let client = GroqIOSClient()
    private let keychain = IOSKeychainStore()
    private var activeSegmentID: UUID?
    private var rotationTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var shouldResumeAfterInterruption = false
    private var interruptionFinalizationTask: Task<Void, Never>?
    private var hasRestored = false
    private var isRestoring = false
    private let segmentDuration: Duration = .seconds(5 * 60)
    private static let vocabularyDefaultsKey = "transcription-vocabulary-hints"

    init() {
        do {
            store = try SessionStore()
        } catch {
            fatalError("Could not create recording store: \(error)")
        }
        apiKey = keychain.loadAPIKey()
        vocabularyHints = TranscriptionVocabulary.normalized(
            UserDefaults.standard.string(forKey: Self.vocabularyDefaultsKey) ?? ""
        )
        capture.onInterruption = { [weak self] event in
            self?.handleInterruption(event)
        }
    }

    var isRecording: Bool { lifecycle.isCapturing && capture.isRecording }
    var presentsActiveControls: Bool { lifecycle.presentsActiveControls }
    var showsResume: Bool { lifecycle.showsResume }
    var currentSession: RecordingSession? { sessions.first { $0.id == currentSessionID } }

    func session(id: UUID) -> RecordingSession? {
        sessions.first { $0.id == id }
    }

    func audioURL(sessionID: UUID, fileName: String) async -> URL {
        await store.audioURL(sessionID: sessionID, fileName: fileName)
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

    func saveSettings(apiKey: String, vocabularyHints: String) -> String? {
        do {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedKey != self.apiKey {
                try keychain.saveAPIKey(normalizedKey)
            }
            let normalizedHints = TranscriptionVocabulary.normalized(vocabularyHints)
            UserDefaults.standard.set(normalizedHints, forKey: Self.vocabularyDefaultsKey)
            self.apiKey = normalizedKey
            self.vocabularyHints = normalizedHints
            retryAll()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func retry(_ sessionID: UUID) {
        Task { await process(sessionID: sessionID) }
    }

    func retryAll() {
        for session in sessions where session.pendingCount > 0 {
            retry(session.id)
        }
    }

    func copyTranscript(_ session: RecordingSession) {
        UIPasteboard.general.string = session.transcript
    }

    func resumeIfNeeded() {
        guard lifecycle == .interrupted, currentSessionID != nil, !capture.isRecording else { return }
        lifecycle = .starting
        Task { await resumeInterruptedSession() }
    }

    func prepareForVisibleApp() async {
        guard UIApplication.shared.applicationState == .active else { return }
        await prepare()
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
        let granted = requestPermission
            ? await capture.requestPermission()
            : AVAudioApplication.shared.recordPermission == .granted
        guard granted else {
            lifecycle = .idle
            errorMessage = IOSAppStrings.Errors.micDenied
            return
        }

        do {
            var session = try await store.createSession()
            sessions.insert(session, at: 0)
            try await startSegment(in: &session)
            currentSessionID = session.id
            lifecycle = .recording
            TimingDiagnostics.shared.record(.recordingStarted, sessionID: session.id)
            replace(session)
            startElapsedAndRotation()
        } catch {
            TimingDiagnostics.shared.record(
                .recordingStartFailed,
                sessionID: currentSessionID,
                code: (error as NSError).code
            )
            currentSessionID = nil
            lifecycle = .idle
            errorMessage = error.localizedDescription
        }
    }

    private func startSegment(in session: inout RecordingSession) async throws {
        let index = session.segments.count
        let fileName = String(format: "segment-%04d.m4a", index + 1)
        let segment = RecordingSession.Segment(index: index, fileName: fileName)
        session.segments.append(segment)
        session.state = .recording
        try await store.save(session)
        let url = await store.audioURL(sessionID: session.id, fileName: fileName)
        do {
            try capture.start(fileURL: url)
            activeSegmentID = segment.id
            errorMessage = nil
        } catch {
            session.segments[index].state = .unavailable
            session.segments[index].endedAt = Date()
            session.segments[index].lastError = "This segment was not recorded"
            session.state = .failed
            try await store.save(session)
            replace(session)
            throw error
        }
    }

    private func stopSession() async {
        lifecycle = .stopping
        shouldResumeAfterInterruption = false
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
        await finalizeActiveSegment(sessionID: sessionID, interrupted: false)
        currentSessionID = nil
        activeSegmentID = nil
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
            var session = try await store.load(sessionID)
            guard let previousIndex = session.segments.firstIndex(where: { $0.id == previousSegmentID }) else {
                return
            }

            let nextIndex = session.segments.count
            let fileName = String(format: "segment-%04d.m4a", nextIndex + 1)
            let nextSegment = RecordingSession.Segment(index: nextIndex, fileName: fileName)
            session.segments.append(nextSegment)
            session.state = .recording

            // Reserve the next segment durably while the current recorder is
            // still active. No storage await occurs during the recorder swap.
            try await store.save(session)
            guard lifecycle == .recording,
                  currentSessionID == sessionID,
                  activeSegmentID == previousSegmentID,
                  capture.isRecording,
                  !Task.isCancelled
            else {
                session.segments.removeAll { $0.id == nextSegment.id }
                try? await store.save(session)
                replace(session)
                return
            }

            let nextURL = await store.audioURL(sessionID: sessionID, fileName: fileName)
            guard lifecycle == .recording,
                  currentSessionID == sessionID,
                  activeSegmentID == previousSegmentID,
                  capture.isRecording,
                  !Task.isCancelled
            else {
                session.segments.removeAll { $0.id == nextSegment.id }
                try? await store.save(session)
                replace(session)
                return
            }

            do {
                try capture.rotate(fileURL: nextURL)
            } catch {
                if capture.isRecording {
                    // Preparation failed before the current recorder stopped.
                    // Roll back only the empty reservation and keep recording.
                    session.segments.removeAll { $0.id == nextSegment.id }
                    try? await store.save(session)
                    replace(session)
                    return
                }

                let endedAt = Date()
                session.segments[previousIndex].endedAt = endedAt
                session.segments[previousIndex].state = .pending
                if let unavailableIndex = session.segments.firstIndex(where: { $0.id == nextSegment.id }) {
                    session.segments[unavailableIndex].endedAt = endedAt
                    session.segments[unavailableIndex].state = .unavailable
                    session.segments[unavailableIndex].lastError = "This segment was not recorded"
                }
                session.state = .failed
                try? await store.save(session)
                replace(session)
                currentSessionID = nil
                activeSegmentID = nil
                lifecycle = .idle
                capture.stop()
                elapsedTask?.cancel()
                await process(sessionID: sessionID)
                errorMessage = "\(IOSAppStrings.Errors.micError) — completed audio is safe"
                return
            }

            let rotatedAt = Date()
            session.segments[previousIndex].endedAt = rotatedAt
            session.segments[previousIndex].state = .pending
            session.segments[previousIndex].lastError = nil
            if let activeIndex = session.segments.firstIndex(where: { $0.id == nextSegment.id }) {
                session.segments[activeIndex].state = .recording
            }
            session.state = .recording
            activeSegmentID = nextSegment.id
            try await store.save(session)
            replace(session)
        } catch {
            // A persistence failure must not tear down a recorder that is still
            // safely capturing audio in the background.
            if !capture.isRecording {
                currentSessionID = nil
                activeSegmentID = nil
                lifecycle = .idle
                errorMessage = "\(IOSAppStrings.Errors.micError) — completed audio is safe"
            }
        }
    }

    private func finalizeActiveSegment(sessionID: UUID, interrupted: Bool) async {
        guard let segmentID = activeSegmentID,
              var session = try? await store.load(sessionID),
              let index = session.segments.firstIndex(where: { $0.id == segmentID })
        else { return }

        session.segments[index].endedAt = Date()
        session.segments[index].state = .pending
        session.segments[index].lastError = nil
        session.state = interrupted ? .interrupted : .processing
        try? await store.save(session)
        replace(session)
        activeSegmentID = nil
    }

    private func handleInterruption(_ event: AudioCaptureService.InterruptionEvent) {
        switch event {
        case .began:
            shouldResumeAfterInterruption = lifecycle == .recording
            guard shouldResumeAfterInterruption else { return }
            lifecycle = .interrupted
            let pendingRotation = rotationTask
            pendingRotation?.cancel()
            rotationTask = nil
            elapsedTask?.cancel()
            guard let sessionID = currentSessionID else { return }
            interruptionFinalizationTask = Task { [weak self] in
                if let pendingRotation {
                    await pendingRotation.value
                }
                guard let self,
                      lifecycle == .interrupted || lifecycle == .starting,
                      currentSessionID == sessionID
                else { return }
                await finalizeActiveSegment(sessionID: sessionID, interrupted: true)
            }
        case .ended(let shouldResume):
            guard shouldResumeAfterInterruption else { return }
            guard shouldResume else {
                shouldResumeAfterInterruption = false
                lifecycle = .interrupted
                return
            }
            lifecycle = .starting
            Task { await resumeInterruptedSession() }
        }
    }

    private func resumeInterruptedSession() async {
        if let interruptionFinalizationTask {
            await interruptionFinalizationTask.value
            self.interruptionFinalizationTask = nil
        }
        guard shouldResumeAfterInterruption || lifecycle == .starting,
              let sessionID = currentSessionID,
              !capture.isRecording
        else { return }
        do {
            var session = try await store.load(sessionID)
            try await startSegment(in: &session)
            lifecycle = .recording
            replace(session)
            shouldResumeAfterInterruption = false
            startElapsedAndRotation()
        } catch {
            lifecycle = .interrupted
            errorMessage = "Audio is safe — tap Resume"
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

    private func process(sessionID: UUID) async {
        if let existing = processingTasks[sessionID] {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performProcessing(sessionID: sessionID)
        }
        processingTasks[sessionID] = task
        await task.value
        processingTasks[sessionID] = nil
    }

    private func performProcessing(sessionID: UUID) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if var session = try? await store.load(sessionID) {
                session.state = .failed
                try? await store.save(session)
                replace(session)
            }
            errorMessage = IOSAppStrings.Transcription.pendingKey
            return
        }

        do {
            var session = try await store.load(sessionID)
            for index in session.segments.indices
            where session.segments[index].state == .pending || session.segments[index].state == .failed {
                session.segments[index].state = .transcribing
                session.segments[index].lastError = nil
                session.state = .processing
                try await store.save(session)
                replace(session)

                let audioURL = await store.audioURL(sessionID: session.id, fileName: session.segments[index].fileName)
                do {
                    let text = try await client.transcribe(
                        fileURL: audioURL,
                        apiKey: apiKey,
                        prompt: vocabularyHints,
                        sessionID: session.id
                    )
                    session.segments[index].transcript = text
                    session.segments[index].state = .complete
                } catch {
                    session.segments[index].state = .failed
                    session.segments[index].lastError = error.localizedDescription
                }
                session.transcript = session.segments
                    .sorted { $0.index < $1.index }
                    .compactMap(\.transcript)
                    .joined(separator: " ")
                try await store.save(session)
                replace(session)
            }

            session.state = session.segments.allSatisfy { $0.state == .complete } ? .complete : .failed
            try await store.save(session)
            replace(session)
            copyTranscriptAutomaticallyIfComplete(session)
        } catch {
            errorMessage = IOSAppStrings.Transcription.audioSafe
        }
    }

    nonisolated static func automaticClipboardText(for session: RecordingSession) -> String? {
        guard session.state == .complete,
              !session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return session.transcript
    }

    private func copyTranscriptAutomaticallyIfComplete(_ session: RecordingSession) {
        guard let transcript = Self.automaticClipboardText(for: session) else { return }
        UIPasteboard.general.string = transcript
    }

    private func replace(_ session: RecordingSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.createdAt > $1.createdAt }
    }
}
