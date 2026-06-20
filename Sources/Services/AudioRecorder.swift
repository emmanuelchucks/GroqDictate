import AudioToolbox
import CoreAudio
import Foundation
import os

struct AudioDevice {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
}

final class AudioRecorder {
    private struct BufferDiagnostics {
        var totalSamples = 0
        var inputPeak: Float = 0
        var outputPeak: Float = 0
        var inputSumSquares: Double = 0
        var outputSumSquares: Double = 0
        var clippedSamples = 0

        mutating func observe(input: Float, output: Float, clipped: Bool) {
            totalSamples += 1
            inputPeak = max(inputPeak, abs(input))
            outputPeak = max(outputPeak, abs(output))
            inputSumSquares += Double(input * input)
            outputSumSquares += Double(output * output)
            if clipped {
                clippedSamples += 1
            }
        }
    }

    private struct RecordingDiagnostics {
        var totalSamples = 0
        var inputPeak: Float = 0
        var outputPeak: Float = 0
        var inputSumSquares: Double = 0
        var outputSumSquares: Double = 0
        var clippedSamples = 0
        var writtenSamples = 0
        var firstNonzeroWrittenSample: Int?
        var lastNonzeroWrittenSample: Int?

        mutating func merge(_ buffer: BufferDiagnostics) {
            totalSamples += buffer.totalSamples
            inputPeak = max(inputPeak, buffer.inputPeak)
            outputPeak = max(outputPeak, buffer.outputPeak)
            inputSumSquares += buffer.inputSumSquares
            outputSumSquares += buffer.outputSumSquares
            clippedSamples += buffer.clippedSamples
        }

        mutating func observeWrittenPCM(_ data: Data) {
            let sampleCount = data.count / 2
            guard sampleCount > 0 else { return }

            data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<sampleCount where samples[index] != 0 {
                    let absoluteIndex = writtenSamples + index
                    if firstNonzeroWrittenSample == nil {
                        firstNonzeroWrittenSample = absoluteIndex
                    }
                    lastNonzeroWrittenSample = absoluteIndex
                }
            }

            writtenSamples += sampleCount
        }
    }

    var inputGain: Float {
        get { _inputGain.withLock { $0 } }
        set { _inputGain.withLock { $0 = newValue } }
    }
    var selectedDeviceUID: String?
    private(set) var isRecording = false
    private let _inputGain = OSAllocatedUnfairLock(initialState: Config.DefaultValue.inputGain)
    private let audioPreprocessor: any AudioPreprocessor
    private let stateLock = NSRecursiveLock()

    init(audioPreprocessor: any AudioPreprocessor = DefaultAudioPreprocessor()) {
        self.audioPreprocessor = audioPreprocessor
    }

    deinit {
        teardownAudioQueue()
        cleanup()
    }

    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _currentLevel
    }

    private var _currentLevel: Float = 0
    private let levelLock = NSLock()

    private struct RecordingSession {
        let id: UUID
        let directoryURL: URL
        let wavURL: URL
        let flacURL: URL
    }

    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt32 = 0
    private var currentSession: RecordingSession?
    private var queueOwnerRetain: Unmanaged<AudioRecorder>?
    private var preparedDeviceUID: String?
    private var isInputQueueStopping = false
    private var isInputQueueIdleStopped = false
    private var isInputQueueWarm = false
    private var warmStartRequestedAt: CFAbsoluteTime?
    private var warmFirstBufferObserved = false
    private var warmFirstNonzeroObserved = false
    private var recordingDiagnostics = RecordingDiagnostics()
    private var isStopping = false
    private var stopShouldProcessRecording = true
    private var stopCompletion: ((URL) -> Void)?
    private var firstBufferObserved = false
    private var recordingReadyObserved = false
    private var recordingRequestedAt: CFAbsoluteTime?
    private var stopRequestedAt: CFAbsoluteTime?
    private var stopDrainBuffersRemaining = 0
    private var stopDrainCompletionScheduled = false
    private var recordingReadyHandler: (() -> Void)?

    private let sessionRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("groqdictate-recordings", isDirectory: true)

    private static let sampleRate: Float64 = 16000
    private static let bufferSize: UInt32 = 4096
    private static let bufferCount = 3
    private static let stopDrainTimeoutSeconds: TimeInterval = 1.0

    func setRecordingReadyHandler(_ handler: (() -> Void)?) {
        stateLock.withLock { recordingReadyHandler = handler }
    }

    func prepareInput() {
        do {
            try prepareInputIfNeeded()
        } catch {
            AppLog.error("failed to warm audio input (\(error.localizedDescription))", category: .audio)
        }
    }

    func start() throws {
        let requestedAt = CFAbsoluteTimeGetCurrent()

        if currentSession != nil || fileHandle != nil || isRecording || isStopping {
            cleanup()
        }

        try prepareInputIfNeeded()

        let session = try makeSession()
        FileManager.default.createFile(atPath: session.wavURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: session.wavURL)
        let inputWasStopped = stateLock.withLock { isInputQueueIdleStopped }

        stateLock.lock()
        currentSession = session
        fileHandle = handle
        bytesWritten = 0
        recordingDiagnostics = RecordingDiagnostics()
        isStopping = false
        stopShouldProcessRecording = true
        stopCompletion = nil
        firstBufferObserved = false
        recordingReadyObserved = false
        recordingRequestedAt = requestedAt
        stopRequestedAt = nil
        stopDrainBuffersRemaining = 0
        stopDrainCompletionScheduled = false
        setLevel(0)
        writeWAVHeader(dataSize: 0)
        isRecording = true
        stateLock.unlock()

        if inputWasStopped {
            do {
                try restartStoppedInputForRecording()
            } catch {
                cleanup()
                throw error
            }
        }

        AppLog.metric(
            "audio_recording_session_started",
            category: .audio,
            level: .debug,
            values: [
                "device_uid": preparedDeviceUID ?? "default",
                "input_warm": isInputQueueWarm ? "true" : "false"
            ]
        )
    }

    func stop(processRecording: Bool = true, completion: @escaping (URL) -> Void) {
        var completeNow = false

        stateLock.lock()
        if isStopping {
            guard !processRecording else {
                stateLock.unlock()
                return
            }

            isRecording = false
            stopShouldProcessRecording = false
            stopCompletion = completion
            stopDrainBuffersRemaining = 0
            stopDrainCompletionScheduled = true
            AppLog.debug("recording session cancel requested while stop drain is pending", category: .audio)
            completeNow = true
            stateLock.unlock()
            completeStoppedRecording()
            return
        }

        guard currentSession != nil else {
            stateLock.unlock()
            return
        }

        isRecording = false
        stopShouldProcessRecording = processRecording
        stopCompletion = completion
        stopRequestedAt = CFAbsoluteTimeGetCurrent()

        if processRecording {
            isStopping = true
            stopDrainBuffersRemaining = max(1, buffers.count)
            stopDrainCompletionScheduled = false
            AppLog.debug("recording session drain requested buffers=\(stopDrainBuffersRemaining)", category: .audio)
        } else {
            isStopping = false
            stopDrainBuffersRemaining = 0
            stopDrainCompletionScheduled = true
            AppLog.debug("recording session immediate cancel requested", category: .audio)
            completeNow = true
        }
        stateLock.unlock()

        if completeNow {
            completeStoppedRecording()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopDrainTimeoutSeconds) { [weak self] in
            self?.completeStopDrainIfStillPending(reason: "timeout")
        }
    }

    func cleanup() {
        let sessionToCleanup: RecordingSession?

        stateLock.lock()
        isRecording = false
        isStopping = false
        stopShouldProcessRecording = true
        stopCompletion = nil
        stopRequestedAt = nil
        stopDrainBuffersRemaining = 0
        stopDrainCompletionScheduled = false
        firstBufferObserved = false
        recordingReadyObserved = false
        recordingRequestedAt = nil
        try? fileHandle?.close()
        fileHandle = nil
        bytesWritten = 0
        recordingDiagnostics = RecordingDiagnostics()
        sessionToCleanup = currentSession
        currentSession = nil
        stateLock.unlock()

        if let sessionToCleanup {
            cleanupSession(sessionToCleanup)
        }
        setLevel(0)
    }

    fileprivate func processBuffer(_ buffer: AudioQueueBufferRef, from queue: AudioQueueRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else {
            reenqueueIfNeeded(buffer, on: queue)
            return
        }

        var shouldWrite = false
        var shouldReenqueue = false
        var needsWarmNonzeroScan = false
        var firstWarmBufferElapsedMs: Double?
        var shouldPauseAfterIdleWarmup = false

        stateLock.lock()
        shouldReenqueue = audioQueue == queue && !isInputQueueStopping && !isInputQueueIdleStopped
        shouldWrite = fileHandle != nil && (isRecording || (isStopping && stopShouldProcessRecording && stopDrainBuffersRemaining > 0))
        needsWarmNonzeroScan = !warmFirstNonzeroObserved
        if !warmFirstBufferObserved {
            warmFirstBufferObserved = true
            firstWarmBufferElapsedMs = elapsedMs(since: warmStartRequestedAt)
            shouldPauseAfterIdleWarmup = !shouldWrite
            markInputWarmLocked(reason: "first_buffer")
        }
        stateLock.unlock()

        guard shouldWrite else {
            let rawPCMData = Data(bytes: buffer.pointee.mAudioData, count: byteCount)
            observeIdleBuffer(queue: queue, hasNonzero: needsWarmNonzeroScan ? Self.containsNonzeroPCM(rawPCMData) : false)
            logFirstWarmBufferIfNeeded(firstWarmBufferElapsedMs)
            if shouldReenqueue {
                reenqueueIfNeeded(buffer, on: queue)
            }
            if shouldPauseAfterIdleWarmup {
                DispatchQueue.main.async { [weak self] in
                    self?.stopInputQueueIfIdle(reason: "warmup_ready")
                }
            }
            return
        }

        let sampleCount = byteCount / 2
        let samples = buffer.pointee.mAudioData.bindMemory(to: Int16.self, capacity: sampleCount)
        let gain = inputGain

        var sumSquares: Float = 0
        var diagnostics = BufferDiagnostics()
        var hasNonzeroOutput = false

        for index in 0..<sampleCount {
            let inputValue = Float(samples[index]) / 32768.0
            var gainedValue = inputValue
            if gain > 1.0 { gainedValue *= gain }

            let clampedValue = max(-1, min(1, gainedValue))
            let clipped = gainedValue != clampedValue
            sumSquares += clampedValue * clampedValue
            diagnostics.observe(input: inputValue, output: clampedValue, clipped: clipped)

            let outputSample = Int16(clamping: Int(clampedValue * 32767))
            samples[index] = outputSample
            if outputSample != 0 {
                hasNonzeroOutput = true
            }
        }

        let rms = min(sqrt(sumSquares / Float(max(sampleCount, 1))) * 3, 1)
        setLevel(rms)

        let processedPCMData = Data(bytes: buffer.pointee.mAudioData, count: byteCount)
        var shouldCompleteStopDrain = false
        var firstWarmNonzeroElapsedMs: Double?
        var firstLiveBufferElapsedMs: Double?
        var recordingReadyCallback: (() -> Void)?

        stateLock.lock()
        if hasNonzeroOutput, !warmFirstNonzeroObserved {
            warmFirstNonzeroObserved = true
            firstWarmNonzeroElapsedMs = elapsedMs(since: warmStartRequestedAt)
        }
        if hasNonzeroOutput, !recordingReadyObserved {
            recordingReadyObserved = true
            recordingReadyCallback = recordingReadyHandler
        }

        if !firstBufferObserved {
            firstBufferObserved = true
            firstLiveBufferElapsedMs = elapsedMs(since: recordingRequestedAt)
        }

        writePCMDataToCurrentFileLocked(processedPCMData, diagnostics: diagnostics)

        if isStopping && stopShouldProcessRecording {
            stopDrainBuffersRemaining = max(0, stopDrainBuffersRemaining - 1)
            if stopDrainBuffersRemaining == 0 && !stopDrainCompletionScheduled {
                stopDrainCompletionScheduled = true
                shouldCompleteStopDrain = true
            }
        }
        stateLock.unlock()

        recordingReadyCallback?()
        logFirstWarmBufferIfNeeded(firstWarmBufferElapsedMs)

        if let firstWarmNonzeroElapsedMs {
            AppLog.metric(
                "audio_input_first_nonzero",
                category: .audio,
                level: .debug,
                values: [
                    "elapsed_ms": String(format: "%.1f", firstWarmNonzeroElapsedMs)
                ]
            )
        }

        if let firstLiveBufferElapsedMs {
            AppLog.metric(
                "audio_recording_first_live_buffer",
                category: .audio,
                level: .debug,
                values: [
                    "elapsed_ms": String(format: "%.1f", firstLiveBufferElapsedMs)
                ]
            )
        }

        if shouldCompleteStopDrain {
            DispatchQueue.main.async { [weak self] in
                self?.completeStopDrainIfStillPending(reason: "buffers_drained")
            }
        }

        if shouldReenqueue {
            reenqueueIfNeeded(buffer, on: queue)
        }
    }

    private func observeIdleBuffer(queue: AudioQueueRef, hasNonzero: Bool) {
        var firstWarmNonzeroElapsedMs: Double?

        stateLock.lock()
        guard audioQueue == queue && !isInputQueueStopping && !isInputQueueIdleStopped else {
            stateLock.unlock()
            return
        }

        if hasNonzero, !warmFirstNonzeroObserved {
            warmFirstNonzeroObserved = true
            firstWarmNonzeroElapsedMs = elapsedMs(since: warmStartRequestedAt)
        }
        stateLock.unlock()

        if let firstWarmNonzeroElapsedMs {
            AppLog.metric(
                "audio_input_first_nonzero",
                category: .audio,
                level: .debug,
                values: [
                    "elapsed_ms": String(format: "%.1f", firstWarmNonzeroElapsedMs)
                ]
            )
        }
    }

    private func logFirstWarmBufferIfNeeded(_ elapsedMs: Double?) {
        guard let elapsedMs else { return }
        AppLog.metric(
            "audio_input_first_buffer",
            category: .audio,
            level: .debug,
            values: [
                "elapsed_ms": String(format: "%.1f", elapsedMs)
            ]
        )
    }

    private static func containsNonzeroPCM(_ data: Data) -> Bool {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return samples.prefix(sampleCount).contains { $0 != 0 }
        }
    }

    private func postProcessRecording(for session: RecordingSession, completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outputURL = self.audioPreprocessor.processRecording(
                wavURL: session.wavURL,
                compressedOutputURL: session.flacURL
            )
            self.preserveDiagnosticAudioIfNeeded(session: session, sourceURL: outputURL, phase: "upload")
            DispatchQueue.main.async { completion(outputURL) }
        }
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        _currentLevel = value
        levelLock.unlock()
    }

    private func prepareInputIfNeeded() throws {
        let targetDeviceUID = selectedDeviceUID

        if audioQueue != nil, preparedDeviceUID == targetDeviceUID {
            return
        }

        if audioQueue != nil {
            if isRecording || isStopping {
                AppLog.debug("audio input reconfiguration deferred while recording is active", category: .audio)
                return
            }
            teardownAudioQueue()
        }

        var format = Self.monoInt16Format()
        var queue: AudioQueueRef?
        let ownerRetain = Unmanaged.passRetained(self)
        let userData = UnsafeMutableRawPointer(ownerRetain.toOpaque())
        let requestedAt = CFAbsoluteTimeGetCurrent()

        do {
            try osCheck(AudioQueueNewInput(&format, Self.inputCallback, userData, nil, nil, 0, &queue))
            guard let queue else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(unimpErr)) }

            audioQueue = queue
            queueOwnerRetain = ownerRetain
            preparedDeviceUID = targetDeviceUID
            isInputQueueStopping = false
            isInputQueueIdleStopped = false
            isInputQueueWarm = false
            warmStartRequestedAt = requestedAt
            warmFirstBufferObserved = false
            warmFirstNonzeroObserved = false

            try osCheck(AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, Self.runningPropertyCallback, userData))
            setInputDevice(on: queue)
            try allocateAndEnqueueBuffers(on: queue)

            AppLog.metric(
                "audio_input_warm_start_requested",
                category: .audio,
                level: .debug,
                values: [
                    "buffer_ms": String(format: "%.1f", durationMs(forByteCount: Int(Self.bufferSize))),
                    "device_uid": targetDeviceUID ?? "default",
                    "sample_rate": String(format: "%.0f", Self.sampleRate)
                ]
            )

            try osCheck(AudioQueueStart(queue, nil))
            AppLog.debug(
                String(format: "audio input warm start returned elapsed=%.1fms", elapsedMs(since: requestedAt) ?? 0),
                category: .audio
            )
            handleQueueRunningPropertyChanged(queue)
        } catch {
            if let queue {
                AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning, Self.runningPropertyCallback, userData)
                AudioQueueDispose(queue, true)
            }
            audioQueue = nil
            buffers.removeAll()
            preparedDeviceUID = nil
            isInputQueueWarm = false
            isInputQueueStopping = false
            isInputQueueIdleStopped = false
            if queueOwnerRetain != nil {
                releaseQueueOwnerRetain()
            } else {
                ownerRetain.release()
            }
            throw error
        }
    }

    private func restartStoppedInputForRecording() throws {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let queueAndBuffers: (AudioQueueRef, [AudioQueueBufferRef])? = stateLock.withLock {
            guard let audioQueue, isInputQueueIdleStopped else { return nil }
            isInputQueueIdleStopped = false
            isInputQueueStopping = false
            isInputQueueWarm = false
            warmStartRequestedAt = startedAt
            warmFirstBufferObserved = false
            warmFirstNonzeroObserved = false
            return (audioQueue, buffers)
        }
        guard let (queue, buffersToEnqueue) = queueAndBuffers else { return }

        for buffer in buffersToEnqueue {
            let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            if enqueueStatus != noErr {
                AppLog.error("failed to enqueue stopped input buffer (status \(enqueueStatus))", category: .audio)
            }
        }

        let startCallAt = CFAbsoluteTimeGetCurrent()
        let status = AudioQueueStart(queue, nil)
        let startReturnMs = (CFAbsoluteTimeGetCurrent() - startCallAt) * 1000
        guard status == noErr else {
            stateLock.withLock {
                if audioQueue == queue {
                    isInputQueueIdleStopped = true
                    isInputQueueWarm = false
                }
            }
            AppLog.error("failed to restart stopped audio input (status \(status))", category: .audio)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        AppLog.metric(
            "audio_input_restart_requested",
            category: .audio,
            level: .debug,
            values: [
                "elapsed_ms": String(format: "%.1f", startReturnMs)
            ]
        )
        handleQueueRunningPropertyChanged(queue)
    }

    private func stopInputQueueIfIdle(reason: String) {
        let queue = stateLock.withLock { () -> AudioQueueRef? in
            guard let audioQueue, !isInputQueueIdleStopped, !isInputQueueStopping, !isRecording, !isStopping else {
                return nil
            }
            isInputQueueStopping = true
            isInputQueueIdleStopped = true
            return audioQueue
        }

        guard let queue else { return }

        let stoppedAt = CFAbsoluteTimeGetCurrent()
        let status = AudioQueueStop(queue, true)
        let stopReturnMs = (CFAbsoluteTimeGetCurrent() - stoppedAt) * 1000

        stateLock.withLock {
            if audioQueue == queue {
                isInputQueueStopping = false
                isInputQueueWarm = false
                if status != noErr {
                    isInputQueueIdleStopped = false
                }
            }
        }

        guard status == noErr else {
            AppLog.error("failed to stop idle audio input (status \(status))", category: .audio)
            return
        }

        setLevel(0)
        AppLog.metric(
            "audio_input_idle_stopped",
            category: .audio,
            level: .debug,
            values: [
                "elapsed_ms": String(format: "%.1f", stopReturnMs),
                "reason": reason
            ]
        )
    }

    private func teardownAudioQueue() {
        let queue = audioQueue
        let userData = queueOwnerRetain.map { UnsafeMutableRawPointer($0.toOpaque()) }

        isInputQueueStopping = true
        audioQueue = nil
        buffers.removeAll()
        preparedDeviceUID = nil
        isInputQueueIdleStopped = false
        isInputQueueWarm = false
        warmStartRequestedAt = nil
        warmFirstBufferObserved = false
        warmFirstNonzeroObserved = false

        if let queue {
            if let userData {
                AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning, Self.runningPropertyCallback, userData)
            }
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }

        releaseQueueOwnerRetain()
        isInputQueueStopping = false
    }

    private func completeStopDrainIfStillPending(reason: String) {
        var shouldComplete = false

        stateLock.lock()
        if isStopping && stopShouldProcessRecording && !stopDrainCompletionScheduled {
            stopDrainCompletionScheduled = true
            stopDrainBuffersRemaining = 0
            shouldComplete = true
        } else if isStopping && stopShouldProcessRecording && stopDrainCompletionScheduled && stopDrainBuffersRemaining == 0 {
            shouldComplete = true
        }
        stateLock.unlock()

        guard shouldComplete else { return }
        AppLog.debug("recording session drain completed reason=\(reason)", category: .audio)
        completeStoppedRecording()
    }

    private func completeStoppedRecording() {
        let session: RecordingSession?
        let shouldProcess: Bool
        let completion: ((URL) -> Void)?

        stateLock.lock()
        guard let activeSession = currentSession else {
            try? fileHandle?.close()
            fileHandle = nil
            isRecording = false
            isStopping = false
            stopCompletion = nil
            recordingReadyObserved = false
            recordingRequestedAt = nil
            stopRequestedAt = nil
            stopDrainBuffersRemaining = 0
            stopDrainCompletionScheduled = false
            stateLock.unlock()
            return
        }

        finalizeWAVHeader()
        try? fileHandle?.close()
        fileHandle = nil
        isRecording = false
        logRecordingDiagnostics()
        logStopLatencyIfAvailable()

        shouldProcess = stopShouldProcessRecording
        completion = stopCompletion
        session = activeSession
        isStopping = false
        stopCompletion = nil
        recordingReadyObserved = false
        recordingRequestedAt = nil
        stopRequestedAt = nil
        stopDrainBuffersRemaining = 0
        stopDrainCompletionScheduled = false
        stateLock.unlock()

        guard let session else { return }

        if shouldProcess {
            preserveDiagnosticAudioIfNeeded(session: session, sourceURL: session.wavURL, phase: "capture")
            stopInputQueueIfIdle(reason: "recording_completed")
        } else {
            cleanup()
            stopInputQueueIfIdle(reason: "recording_cancelled")
            DispatchQueue.main.async { completion?(session.wavURL) }
            return
        }

        if let completion {
            postProcessRecording(for: session, completion: completion)
        }
    }

    private func handleQueueRunningPropertyChanged(_ queue: AudioQueueRef) {
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &isRunning, &size)
        guard status == noErr else {
            AppLog.error("failed to read audio queue running state (status \(status))", category: .audio)
            return
        }

        stateLock.lock()
        guard audioQueue == queue else {
            stateLock.unlock()
            return
        }

        if isRunning == 1 {
            markInputWarmLocked(reason: "is_running")
        } else {
            isInputQueueWarm = false
        }
        stateLock.unlock()
    }

    private func markInputWarmLocked(reason: String) {
        guard !isInputQueueWarm else { return }
        isInputQueueWarm = true

        AppLog.metric(
            "audio_input_warm_ready",
            category: .audio,
            level: .debug,
            values: [
                "device_uid": preparedDeviceUID ?? "default",
                "elapsed_ms": String(format: "%.1f", elapsedMs(since: warmStartRequestedAt) ?? 0),
                "reason": reason
            ]
        )
    }

    private func reenqueueIfNeeded(_ buffer: AudioQueueBufferRef, on queue: AudioQueueRef) {
        stateLock.lock()
        let shouldReenqueue = audioQueue == queue && !isInputQueueStopping && !isInputQueueIdleStopped
        stateLock.unlock()

        if shouldReenqueue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func writePCMDataToCurrentFileLocked(_ data: Data, diagnostics: BufferDiagnostics?) {
        guard !data.isEmpty else { return }
        fileHandle?.write(data)
        bytesWritten += UInt32(data.count)
        recordingDiagnostics.observeWrittenPCM(data)
        if let diagnostics {
            recordingDiagnostics.merge(diagnostics)
        }
    }

    private func logStopLatencyIfAvailable() {
        guard let stopRequestedAt else { return }
        AppLog.debug(
            String(format: "recording session stop completed elapsed=%.1fms", (CFAbsoluteTimeGetCurrent() - stopRequestedAt) * 1000),
            category: .audio
        )
    }

    private func preserveDiagnosticAudioIfNeeded(session: RecordingSession, sourceURL: URL, phase: String) {
        guard AppConstants.Diagnostics.preserveAudioEnabled else { return }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        let capturesDirectory = AppConstants.Diagnostics.diagnosticsDirectory
            .appendingPathComponent("AudioCaptures", isDirectory: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let destinationURL = capturesDirectory
            .appendingPathComponent("\(session.id.uuidString)-\(phase).\(fileExtension)", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int) ?? 0
            AppLog.metric(
                "audio_diagnostic_capture",
                category: .audio,
                level: .debug,
                values: [
                    "bytes": String(bytes),
                    "filename": destinationURL.lastPathComponent,
                    "phase": phase
                ]
            )
        } catch {
            AppLog.error("failed to preserve diagnostic audio (\(error.localizedDescription))", category: .audio)
        }
    }

    private func releaseQueueOwnerRetain() {
        queueOwnerRetain?.release()
        queueOwnerRetain = nil
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue().processBuffer(buffer, from: queue)
    }

    private static let runningPropertyCallback: AudioQueuePropertyListenerProc = { userData, queue, propertyID in
        guard propertyID == kAudioQueueProperty_IsRunning, let userData else { return }
        Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue().handleQueueRunningPropertyChanged(queue)
    }

    private func setInputDevice(on queue: AudioQueueRef) {
        guard let uid = selectedDeviceUID, !uid.isEmpty else { return }
        var cfUID: CFString? = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString?>.size)
            )
        }
        if status != noErr {
            AppLog.error("failed to set input device '\(uid)' (status \(status))", category: .audio)
        }
    }

    private func makeSession() throws -> RecordingSession {
        try FileManager.default.createDirectory(at: sessionRootURL, withIntermediateDirectories: true)

        let id = UUID()
        let directoryURL = sessionRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        return RecordingSession(
            id: id,
            directoryURL: directoryURL,
            wavURL: directoryURL.appendingPathComponent(AppConstants.TempFiles.wav, isDirectory: false),
            flacURL: directoryURL.appendingPathComponent(AppConstants.TempFiles.flac, isDirectory: false)
        )
    }

    private func cleanupSession(_ session: RecordingSession) {
        try? FileManager.default.removeItem(at: session.directoryURL)
    }

    private func writeWAVHeader(dataSize: UInt32) {
        fileHandle?.write(Self.wavHeader(dataSize: dataSize))
    }

    private func finalizeWAVHeader() {
        guard let fileHandle else { return }
        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(Self.wavHeader(dataSize: bytesWritten))
    }

    private func logRecordingDiagnostics() {
        guard recordingDiagnostics.writtenSamples > 0 else { return }

        let writtenSampleCount = Double(recordingDiagnostics.writtenSamples)
        let recordingDurationMs = writtenSampleCount / Self.sampleRate * 1000
        let captureSampleCount = Double(max(recordingDiagnostics.totalSamples, 1))
        let inputRMS = recordingDiagnostics.totalSamples > 0
            ? sqrt(recordingDiagnostics.inputSumSquares / captureSampleCount)
            : 0
        let outputRMS = recordingDiagnostics.totalSamples > 0
            ? sqrt(recordingDiagnostics.outputSumSquares / captureSampleCount)
            : 0
        let clippedRatio = recordingDiagnostics.totalSamples > 0
            ? Double(recordingDiagnostics.clippedSamples) / Double(recordingDiagnostics.totalSamples) * 100
            : 0
        let leadingZeroMs = Double(recordingDiagnostics.firstNonzeroWrittenSample ?? recordingDiagnostics.writtenSamples)
            / Self.sampleRate * 1000
        let trailingZeroSamples: Int
        if let lastNonzero = recordingDiagnostics.lastNonzeroWrittenSample {
            trailingZeroSamples = max(0, recordingDiagnostics.writtenSamples - lastNonzero - 1)
        } else {
            trailingZeroSamples = recordingDiagnostics.writtenSamples
        }
        let trailingZeroMs = Double(trailingZeroSamples) / Self.sampleRate * 1000

        AppLog.metric(
            "audio_capture_quality",
            category: .audio,
            level: .debug,
            values: [
                "clipped": recordingDiagnostics.clippedSamples > 0 ? "true" : "false",
                "clipped_ratio_pct": String(format: "%.3f", clippedRatio),
                "clipped_samples": String(recordingDiagnostics.clippedSamples),
                "duration_ms": String(format: "%.0f", recordingDurationMs),
                "gain": String(format: "%.1f", inputGain),
                "input_peak_dbfs": Self.formatDBFS(recordingDiagnostics.inputPeak),
                "input_rms_dbfs": Self.formatDBFS(Float(inputRMS)),
                "leading_exact_zero_ms": String(format: "%.0f", leadingZeroMs),
                "output_peak_dbfs": Self.formatDBFS(recordingDiagnostics.outputPeak),
                "output_rms_dbfs": Self.formatDBFS(Float(outputRMS)),
                "samples": String(recordingDiagnostics.writtenSamples),
                "trailing_exact_zero_ms": String(format: "%.0f", trailingZeroMs)
            ]
        )
    }

    private func elapsedMs(since start: CFAbsoluteTime?) -> Double? {
        guard let start else { return nil }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func durationMs(forByteCount byteCount: Int) -> Double {
        Double(byteCount / 2) / Self.sampleRate * 1000
    }

    private static func formatDBFS(_ value: Float) -> String {
        let floored = max(Double(abs(value)), 0.000_001)
        return String(format: "%.1f", 20 * log10(floored))
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        var data = Data(capacity: 44)
        data.append(ascii: "RIFF")
        data.append(uint32: 36 + dataSize)
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(uint32: 16)
        data.append(uint16: 1)
        data.append(uint16: 1)
        data.append(uint32: 16000)
        data.append(uint32: 32000)
        data.append(uint16: 2)
        data.append(uint16: 16)
        data.append(ascii: "data")
        data.append(uint32: dataSize)
        return data
    }

    private static func monoInt16Format() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private func allocateAndEnqueueBuffers(on queue: AudioQueueRef) throws {
        buffers.removeAll()
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            try osCheck(AudioQueueAllocateBuffer(queue, Self.bufferSize, &buffer))
            guard let buffer else { continue }
            buffers.append(buffer)
            try osCheck(AudioQueueEnqueueBuffer(queue, buffer, 0, nil))
        }
    }

    private func osCheck(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func availableInputDevices() -> [AudioDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)

        return ids.compactMap { id in
            guard inputChannelCount(for: id) > 0 else { return nil }
            let name = stringProperty(kAudioDevicePropertyDeviceNameCFString, of: id)
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id)
            return AudioDevice(uid: uid, name: name, deviceID: id)
        }
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { pointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return "" }
        return value as String
    }
}

private extension NSLocking {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Data {
    mutating func append(ascii: String) {
        append(contentsOf: ascii.utf8)
    }

    mutating func append(uint16: UInt16) {
        var value = uint16.littleEndian
        append(Data(bytes: &value, count: 2))
    }

    mutating func append(uint32: UInt32) {
        var value = uint32.littleEndian
        append(Data(bytes: &value, count: 4))
    }
}
