import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
}

/// Records microphone audio to a 16kHz 16-bit mono WAV file using AudioQueue.
///
/// We use AudioQueue instead of AVAudioEngine because AVAudioEngine has a per-process
/// format cache bug: on first mic access after permission grant, macOS reconfigures the
/// audio hardware. AVAudioEngine caches the tap format before the reconfig, then fails
/// with -10868 (format mismatch) on every subsequent start attempt — even with a fresh
/// instance. AudioQueue handles this internally with its own retry mechanism.
class AudioRecorder {
    var inputGain: Float = 5.0
    var selectedDeviceUID: String?
    var currentLevel: Float = 0
    private(set) var isRecording = false

    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var fileHandle: FileHandle?
    private var bytesWritten: UInt32 = 0

    private let wavURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("groqdictate.wav")
    private let flacURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("groqdictate.flac")

    // Recordings over 10MB (~5 min) get compressed to FLAC before upload.
    // Under that, WAV is faster (no compression overhead, Groq prefers WAV).
    private static let flacThreshold = 10 * 1024 * 1024

    private static let sampleRate: Float64 = 16000
    private static let bufferSize: UInt32 = 4096  // ~128ms per buffer at 16kHz
    private static let bufferCount = 3

    // MARK: - Recording

    func start() throws {
        try? FileManager.default.removeItem(at: wavURL)
        FileManager.default.createFile(atPath: wavURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: wavURL)
        bytesWritten = 0
        writeWAVHeader(dataSize: 0)

        var format = Self.monoInt16Format()
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var queue: AudioQueueRef?
        try osCheck(AudioQueueNewInput(&format, Self.inputCallback, selfPtr, nil, nil, 0, &queue))
        audioQueue = queue!

        setInputDevice(on: queue!)
        try allocateAndEnqueueBuffers(on: queue!)
        try osCheck(AudioQueueStart(queue!, nil))
        isRecording = true
    }

    func stop(completion: @escaping (URL) -> Void) {
        isRecording = false

        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
            buffers.removeAll()
        }

        finalizeWAVHeader()
        try? fileHandle?.close()
        fileHandle = nil

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0

        guard fileSize >= Self.flacThreshold else {
            DispatchQueue.main.async { completion(self.wavURL) }
            return
        }

        compressToFLAC(completion: completion)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }

    // MARK: - AudioQueue Callback

    /// Called on AudioQueue's internal thread for each filled buffer.
    fileprivate func processBuffer(_ buffer: AudioQueueBufferRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else { return }

        let sampleCount = byteCount / 2
        let samples = buffer.pointee.mAudioData.bindMemory(to: Int16.self, capacity: sampleCount)
        let gain = inputGain

        // Apply gain in-place and compute RMS for waveform display
        var sumSquares: Float = 0
        for i in 0..<sampleCount {
            var s = Float(samples[i]) / 32768.0
            if gain > 1.0 { s *= gain }
            sumSquares += s * s
            samples[i] = Int16(clamping: Int(max(-1, min(1, s)) * 32767))
        }
        currentLevel = min(sqrt(sumSquares / Float(max(sampleCount, 1))) * 3, 1)

        fileHandle?.write(Data(bytes: buffer.pointee.mAudioData, count: byteCount))
        bytesWritten += UInt32(byteCount)

        if let queue = audioQueue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        Unmanaged<AudioRecorder>.fromOpaque(userData).takeUnretainedValue().processBuffer(buffer)
    }

    // MARK: - Device Selection

    /// Sets the input device on the queue. Uses CFString UID, not AudioDeviceID —
    /// kAudioQueueProperty_CurrentDevice takes a CFStringRef per AudioQueue.h.
    private func setInputDevice(on queue: AudioQueueRef) {
        guard let uid = selectedDeviceUID, !uid.isEmpty else { return }
        var cfUID: CFString = uid as CFString
        let status = AudioQueueSetProperty(
            queue, kAudioQueueProperty_CurrentDevice,
            &cfUID, UInt32(MemoryLayout<CFString>.size))
        if status != noErr {
            NSLog("GroqDictate: failed to set input device '\(uid)' (status \(status))")
        }
    }

    // MARK: - WAV File

    private func writeWAVHeader(dataSize: UInt32) {
        fileHandle?.write(Self.wavHeader(dataSize: dataSize))
    }

    private func finalizeWAVHeader() {
        guard let fh = fileHandle else { return }
        fh.seek(toFileOffset: 0)
        fh.write(Self.wavHeader(dataSize: bytesWritten))
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        var d = Data(capacity: 44)
        d.append(ascii: "RIFF")
        d.append(uint32: 36 + dataSize)
        d.append(ascii: "WAVE")
        d.append(ascii: "fmt ")
        d.append(uint32: 16)               // PCM subchunk size
        d.append(uint16: 1)                 // PCM format
        d.append(uint16: 1)                 // mono
        d.append(uint32: 16000)             // sample rate
        d.append(uint32: 32000)             // byte rate (16000 * 1 * 2)
        d.append(uint16: 2)                 // block align (channels * bytes per sample)
        d.append(uint16: 16)                // bits per sample
        d.append(ascii: "data")
        d.append(uint32: dataSize)
        return d
    }

    // MARK: - FLAC Compression

    private func compressToFLAC(completion: @escaping (URL) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [wavURL, flacURL] in
            try? FileManager.default.removeItem(at: flacURL)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            proc.arguments = ["-f", "flac", "-d", "flac", "-c", "1", wavURL.path, flacURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            let ok = (try? proc.run()).map { proc.waitUntilExit(); return proc.terminationStatus == 0 } ?? false
            let url = ok && FileManager.default.fileExists(atPath: flacURL.path) ? flacURL : wavURL
            if url == flacURL { try? FileManager.default.removeItem(at: wavURL) }

            DispatchQueue.main.async { completion(url) }
        }
    }

    // MARK: - Helpers

    private static func monoInt16Format() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    }

    private func allocateAndEnqueueBuffers(on queue: AudioQueueRef) throws {
        buffers.removeAll()
        for _ in 0..<Self.bufferCount {
            var buf: AudioQueueBufferRef?
            try osCheck(AudioQueueAllocateBuffer(queue, Self.bufferSize, &buf))
            buffers.append(buf!)
            AudioQueueEnqueueBuffer(queue, buf!, 0, nil)
        }
    }

    private func osCheck(_ status: OSStatus) throws {
        guard status != noErr else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    // MARK: - Device Enumeration

    static func availableInputDevices() -> [AudioDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

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
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buf) == noErr else { return 0 }

        return UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value as String
    }
}

// MARK: - Data Helpers for WAV Header

private extension Data {
    mutating func append(ascii: String) { append(contentsOf: ascii.utf8) }
    mutating func append(uint16: UInt16) { var v = uint16.littleEndian; append(Data(bytes: &v, count: 2)) }
    mutating func append(uint32: UInt32) { var v = uint32.littleEndian; append(Data(bytes: &v, count: 4)) }
}
