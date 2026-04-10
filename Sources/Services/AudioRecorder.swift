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
    private struct RecordingDiagnostics {
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

    var inputGain: Float {
        get { _inputGain.withLock { $0 } }
        set { _inputGain.withLock { $0 = newValue } }
    }
    var selectedDeviceUID: String?
    private(set) var isRecording = false
    private let _inputGain = OSAllocatedUnfairLock(initialState: Config.DefaultValue.inputGain)
    private let audioPreprocessor: any AudioPreprocessor

    init(audioPreprocessor: any AudioPreprocessor = DefaultAudioPreprocessor()) {
        self.audioPreprocessor = audioPreprocessor
    }

    deinit {
        teardownAudioQueue()
        try? fileHandle?.close()
        if let session = currentSession {
            cleanupSession(session)
        }
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
    private var recordingDiagnostics = RecordingDiagnostics()

    private let sessionRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("groqdictate-recordings", isDirectory: true)

    private static let sampleRate: Float64 = 16000
    private static let bufferSize: UInt32 = 4096
    private static let bufferCount = 3

    func start() throws {
        if let existingSession = currentSession {
            cleanupSession(existingSession)
            currentSession = nil
        }

        let session = try makeSession()
        currentSession = session
        FileManager.default.createFile(atPath: session.wavURL.path, contents: nil)

        fileHandle = try FileHandle(forWritingTo: session.wavURL)
        bytesWritten = 0
        recordingDiagnostics = RecordingDiagnostics()
        setLevel(0)
        writeWAVHeader(dataSize: 0)

        var format = Self.monoInt16Format()
        var queue: AudioQueueRef?
        let ownerRetain = Unmanaged.passRetained(self)
        let userData = UnsafeMutableRawPointer(ownerRetain.toOpaque())

        do {
            try osCheck(AudioQueueNewInput(&format, Self.inputCallback, userData, nil, nil, 0, &queue))
            guard let queue else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(unimpErr)) }

            audioQueue = queue
            queueOwnerRetain = ownerRetain
            setInputDevice(on: queue)
            try allocateAndEnqueueBuffers(on: queue)
            try osCheck(AudioQueueStart(queue, nil))
            isRecording = true
        } catch {
            if let queue {
                AudioQueueDispose(queue, true)
            }
            audioQueue = nil
            buffers.removeAll()
            if queueOwnerRetain != nil {
                releaseQueueOwnerRetain()
            } else {
                ownerRetain.release()
            }
            try? fileHandle?.close()
            fileHandle = nil
            bytesWritten = 0
            cleanupSession(session)
            currentSession = nil
            throw error
        }
    }

    func stop(processRecording: Bool = true, completion: @escaping (URL) -> Void) {
        isRecording = false

        teardownAudioQueue()

        finalizeWAVHeader()
        try? fileHandle?.close()
        fileHandle = nil
        logRecordingDiagnostics()

        guard let session = currentSession else { return }

        guard processRecording else {
            DispatchQueue.main.async { completion(session.wavURL) }
            return
        }

        postProcessRecording(for: session, completion: completion)
    }

    func cleanup() {
        if let session = currentSession {
            cleanupSession(session)
            currentSession = nil
        }
        setLevel(0)
    }

    fileprivate func processBuffer(_ buffer: AudioQueueBufferRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else { return }

        let sampleCount = byteCount / 2
        let samples = buffer.pointee.mAudioData.bindMemory(to: Int16.self, capacity: sampleCount)
        let gain = inputGain

        var sumSquares: Float = 0
        for i in 0..<sampleCount {
            let inputValue = Float(samples[i]) / 32768.0
            var gainedValue = inputValue
            if gain > 1.0 { gainedValue *= gain }

            let clampedValue = max(-1, min(1, gainedValue))
            let clipped = gainedValue != clampedValue
            sumSquares += clampedValue * clampedValue
            recordingDiagnostics.observe(input: inputValue, output: clampedValue, clipped: clipped)

            samples[i] = Int16(clamping: Int(clampedValue * 32767))
        }

        let rms = min(sqrt(sumSquares / Float(max(sampleCount, 1))) * 3, 1)
        setLevel(rms)

        fileHandle?.write(Data(bytes: buffer.pointee.mAudioData, count: byteCount))
        bytesWritten += UInt32(byteCount)

        if let queue = audioQueue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func postProcessRecording(for session: RecordingSession, completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outputURL = self.audioPreprocessor.processRecording(
                wavURL: session.wavURL,
                compressedOutputURL: session.flacURL
            )
            DispatchQueue.main.async { completion(outputURL) }
        }
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        _currentLevel = value
        levelLock.unlock()
    }

    private func teardownAudioQueue() {
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        audioQueue = nil
        buffers.removeAll()
        releaseQueueOwnerRetain()
    }

    private func releaseQueueOwnerRetain() {
        queueOwnerRetain?.release()
        queueOwnerRetain = nil
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue().processBuffer(buffer)
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
        guard recordingDiagnostics.totalSamples > 0 else { return }

        let sampleCount = Double(recordingDiagnostics.totalSamples)
        let durationMs = sampleCount / Self.sampleRate * 1000
        let inputRMS = sqrt(recordingDiagnostics.inputSumSquares / sampleCount)
        let outputRMS = sqrt(recordingDiagnostics.outputSumSquares / sampleCount)
        let clippedRatio = Double(recordingDiagnostics.clippedSamples) / sampleCount * 100

        AppLog.metric(
            "audio_capture_quality",
            category: .audio,
            level: .debug,
            values: [
                "clipped": recordingDiagnostics.clippedSamples > 0 ? "true" : "false",
                "clipped_ratio_pct": String(format: "%.3f", clippedRatio),
                "clipped_samples": String(recordingDiagnostics.clippedSamples),
                "duration_ms": String(format: "%.0f", durationMs),
                "gain": String(format: "%.1f", inputGain),
                "input_peak_dbfs": Self.formatDBFS(recordingDiagnostics.inputPeak),
                "input_rms_dbfs": Self.formatDBFS(Float(inputRMS)),
                "output_peak_dbfs": Self.formatDBFS(recordingDiagnostics.outputPeak),
                "output_rms_dbfs": Self.formatDBFS(Float(outputRMS)),
                "samples": String(recordingDiagnostics.totalSamples)
            ]
        )
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
            mScope: kAudioDevicePropertyScopeInput,
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
