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
    var inputGain: Float {
        get { _inputGain.withLock { $0 } }
        set { _inputGain.withLock { $0 = newValue } }
    }
    var selectedDeviceUID: String?
    private(set) var isRecording = false
    private let _inputGain = OSAllocatedUnfairLock(initialState: Float(5.0))

    deinit {
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        try? fileHandle?.close()
    }

    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _currentLevel
    }

    private var _currentLevel: Float = 0
    private let levelLock = NSLock()

    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt32 = 0

    private let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent(AppConstants.TempFiles.wav)
    private let flacURL = FileManager.default.temporaryDirectory.appendingPathComponent(AppConstants.TempFiles.flac)

    private static let flacThreshold = 10 * 1024 * 1024
    private static let sampleRate: Float64 = 16000
    private static let bufferSize: UInt32 = 4096
    private static let bufferCount = 3

    private static let trimWindowMs: Float64 = 20
    private static let trimSpeechRMSThreshold: Float = 0.005
    private static let trimMinLeadingSpeechWindows = 4
    private static let trimMinTrailingSpeechWindows = 8
    private static let trimLeadingPaddingMs: Float64 = 120
    private static let trimTrailingPaddingMs: Float64 = 150
    private static let trimMinLeadingTrimMs: Float64 = 180
    private static let trimMinTrailingTrimMs: Float64 = 120
    private static let trimMinResultMs: Float64 = 300

    func start() throws {
        try? FileManager.default.removeItem(at: wavURL)
        FileManager.default.createFile(atPath: wavURL.path, contents: nil)

        fileHandle = try FileHandle(forWritingTo: wavURL)
        bytesWritten = 0
        setLevel(0)
        writeWAVHeader(dataSize: 0)

        var format = Self.monoInt16Format()
        let pointer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        var queue: AudioQueueRef?
        try osCheck(AudioQueueNewInput(&format, Self.inputCallback, pointer, nil, nil, 0, &queue))
        guard let queue else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(unimpErr)) }

        audioQueue = queue
        setInputDevice(on: queue)
        try allocateAndEnqueueBuffers(on: queue)
        try osCheck(AudioQueueStart(queue, nil))
        isRecording = true
    }

    func stop(processRecording: Bool = true, completion: @escaping (URL) -> Void) {
        isRecording = false

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
            buffers.removeAll()
            Unmanaged.passUnretained(self).release()
        }

        finalizeWAVHeader()
        try? fileHandle?.close()
        fileHandle = nil

        guard processRecording else {
            DispatchQueue.main.async { completion(self.wavURL) }
            return
        }

        postProcessRecording(completion: completion)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
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
            var value = Float(samples[i]) / 32768.0
            if gain > 1.0 { value *= gain }
            sumSquares += value * value
            samples[i] = Int16(clamping: Int(max(-1, min(1, value)) * 32767))
        }

        let rms = min(sqrt(sumSquares / Float(max(sampleCount, 1))) * 3, 1)
        setLevel(rms)

        fileHandle?.write(Data(bytes: buffer.pointee.mAudioData, count: byteCount))
        bytesWritten += UInt32(byteCount)

        if let queue = audioQueue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func postProcessRecording(completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.trimWAVSilenceEdgesIfNeeded()

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: self.wavURL.path)[.size] as? Int) ?? 0
            guard fileSize >= Self.flacThreshold else {
                DispatchQueue.main.async { completion(self.wavURL) }
                return
            }

            self.compressToFLAC(completion: completion)
        }
    }

    private func trimWAVSilenceEdgesIfNeeded() {
        guard let data = try? Data(contentsOf: wavURL, options: .mappedIfSafe), data.count > 44 else { return }

        let sampleByteCount = data.count - 44
        guard sampleByteCount >= 2 else { return }

        let sampleCount = sampleByteCount / 2
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, from: 44..<(44 + sampleCount * 2))
        }

        guard var (startSample, endSample) = Self.detectSpeechBounds(samples: samples) else { return }

        let leadingPadding = Int(Self.sampleRate * Self.trimLeadingPaddingMs / 1000)
        let trailingPadding = Int(Self.sampleRate * Self.trimTrailingPaddingMs / 1000)
        startSample = max(0, startSample - leadingPadding)
        endSample = min(sampleCount, endSample + trailingPadding)

        let minLeadingTrim = Int(Self.sampleRate * Self.trimMinLeadingTrimMs / 1000)
        let minTrailingTrim = Int(Self.sampleRate * Self.trimMinTrailingTrimMs / 1000)
        if startSample < minLeadingTrim { startSample = 0 }
        if (sampleCount - endSample) < minTrailingTrim { endSample = sampleCount }

        guard startSample < endSample else { return }
        guard !(startSample == 0 && endSample == sampleCount) else { return }

        let minResultSamples = Int(Self.sampleRate * Self.trimMinResultMs / 1000)
        guard (endSample - startSample) >= minResultSamples else { return }

        let trimmedSamples = Array(samples[startSample..<endSample])
        let trimmedPCM = trimmedSamples.withUnsafeBytes { Data($0) }

        var trimmedWAV = Data(capacity: 44 + trimmedPCM.count)
        trimmedWAV.append(Self.wavHeader(dataSize: UInt32(trimmedPCM.count)))
        trimmedWAV.append(trimmedPCM)

        do {
            try trimmedWAV.write(to: wavURL, options: .atomic)
            bytesWritten = UInt32(trimmedPCM.count)
        } catch {
            AppLog.error("failed to trim silence (\(error.localizedDescription))", category: .audio)
        }
    }

    private static func detectSpeechBounds(samples: [Int16]) -> (startSample: Int, endSample: Int)? {
        let windowSize = max(1, Int(sampleRate * trimWindowMs / 1000))
        let totalWindows = Int(ceil(Double(samples.count) / Double(windowSize)))
        guard totalWindows > 0 else { return nil }

        var speechWindows = [Bool](repeating: false, count: totalWindows)
        for index in 0..<totalWindows {
            let start = index * windowSize
            let end = min(samples.count, start + windowSize)
            guard start < end else { continue }

            var sumSquares: Double = 0
            for sample in samples[start..<end] {
                let normalized = Double(sample) / 32768.0
                sumSquares += normalized * normalized
            }

            let rms = sqrt(sumSquares / Double(end - start))
            speechWindows[index] = rms >= Double(trimSpeechRMSThreshold)
        }

        let leadingRequired = max(1, min(trimMinLeadingSpeechWindows, speechWindows.count))
        let trailingRequired = max(1, min(trimMinTrailingSpeechWindows, speechWindows.count))

        var firstSpeechWindow: Int?
        var streak = 0
        for index in 0..<speechWindows.count {
            if speechWindows[index] {
                streak += 1
                if streak >= leadingRequired {
                    firstSpeechWindow = index - streak + 1
                    break
                }
            } else {
                streak = 0
            }
        }

        guard let firstSpeechWindow else { return nil }

        var lastSpeechWindow: Int?
        streak = 0
        for index in stride(from: speechWindows.count - 1, through: 0, by: -1) {
            if speechWindows[index] {
                streak += 1
                if streak >= trailingRequired {
                    lastSpeechWindow = index + trailingRequired - 1
                    break
                }
            } else {
                streak = 0
            }
        }

        guard let lastSpeechWindow, firstSpeechWindow <= lastSpeechWindow else { return nil }

        let startSample = firstSpeechWindow * windowSize
        let endSample = min(samples.count, (lastSpeechWindow + 1) * windowSize)
        return (startSample, endSample)
    }

    private func setLevel(_ value: Float) {
        levelLock.lock()
        _currentLevel = value
        levelLock.unlock()
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

    private func writeWAVHeader(dataSize: UInt32) {
        fileHandle?.write(Self.wavHeader(dataSize: dataSize))
    }

    private func finalizeWAVHeader() {
        guard let fileHandle else { return }
        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(Self.wavHeader(dataSize: bytesWritten))
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

    private func compressToFLAC(completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [wavURL, flacURL] in
            try? FileManager.default.removeItem(at: flacURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "flac", "-d", "flac", "-c", "1", wavURL.path, flacURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let succeeded = (try? process.run()).map {
                process.waitUntilExit()
                return process.terminationStatus == 0
            } ?? false

            let outputURL = succeeded && FileManager.default.fileExists(atPath: flacURL.path) ? flacURL : wavURL
            if outputURL == flacURL {
                try? FileManager.default.removeItem(at: wavURL)
            }

            DispatchQueue.main.async { completion(outputURL) }
        }
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
