import Accelerate
import AVFoundation
import Cocoa
import CoreAudio

struct AudioDevice {
    let uid: String
    let name: String
}

class AudioRecorder {
    var inputGain: Float = 5.0

    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "groqdictate.wav")
    private let flacURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "groqdictate.flac")

    /// Current audio level (written on audio thread, read on main for waveform display)
    var currentLevel: Float = 0

    // Serial queue for file writes (keeps I/O off the real-time audio thread)
    private let writeQueue = DispatchQueue(label: "com.groqdictate.audiowrite")

    // Only compress to FLAC if WAV exceeds this size.
    // Groq docs: "For lower latency, convert your files to wav format"
    private static let flacThresholdBytes = 10 * 1024 * 1024  // 10MB ≈ 5 min

    // MARK: - Device Enumeration

    static func availableInputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices)

        var result: [AudioDevice] = []
        for device in devices {
            var inputChannels = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var chanSize: UInt32 = 0
            guard
                AudioObjectGetPropertyDataSize(device, &inputChannels, 0, nil, &chanSize) == noErr,
                chanSize > 0
            else { continue }

            let bufferListPtr = UnsafeMutableRawPointer.allocate(
                byteCount: Int(chanSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListPtr.deallocate() }

            guard
                AudioObjectGetPropertyData(
                    device, &inputChannels, 0, nil, &chanSize, bufferListPtr) == noErr
            else { continue }

            let ablPointer = UnsafeMutableAudioBufferListPointer(
                bufferListPtr.assumingMemoryBound(to: AudioBufferList.self))
            let totalChannels = ablPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard totalChannels > 0 else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName)

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &cfUID)

            result.append(AudioDevice(uid: cfUID as String, name: cfName as String))
        }
        return result
    }

    /// Pre-allocate audio resources so first recording starts faster
    func warmup() {
        audioEngine.prepare()
    }

    // MARK: - Recording

    func start() throws {
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Record as float32 at 16kHz mono (stable for AVAudioFile writes)
        let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        try? FileManager.default.removeItem(at: wavURL)
        audioFile = try AVAudioFile(forWriting: wavURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let converter = AVAudioConverter(from: hwFormat, to: recordFormat)!
        converter.sampleRateConverterQuality = .min  // speech doesn't need audiophile resampling
        let gain = inputGain

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate)
            guard frameCount > 0 else { return }

            guard
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: recordFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                guard !consumed else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            // Apply gain and compute RMS via Accelerate (NEON SIMD on ARM64)
            if let channelData = convertedBuffer.floatChannelData {
                let ptr = channelData[0]
                let len = vDSP_Length(convertedBuffer.frameLength)
                if gain > 1.0 {
                    var g = gain
                    vDSP_vsmul(ptr, 1, &g, ptr, 1, len)
                }
                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, len)
                self.currentLevel = min(rms * 3.0, 1.0)
            }

            // AVAudioFile handles float32→int16 conversion on write (via processingFormat→fileFormat)
            self.writeQueue.async { [weak self] in
                autoreleasepool {
                    try? self?.audioFile?.write(from: convertedBuffer)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stop recording. Short recordings sent as WAV; long ones compressed via macOS-native afconvert.
    func stop(completion: @escaping (URL) -> Void) {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Ensure pending writes complete before reading the file
        writeQueue.sync {
            self.audioFile = nil
        }

        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0

        if fileSize < Self.flacThresholdBytes {
            DispatchQueue.main.async { completion(self.wavURL) }
            return
        }

        // Compress with macOS-native afconvert (ships with every Mac, zero dependencies)
        DispatchQueue.global(qos: .userInitiated).async { [wavURL, flacURL] in
            try? FileManager.default.removeItem(at: flacURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "flac", "-d", "flac", "-c", "1", wavURL.path, flacURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0
                    && FileManager.default.fileExists(atPath: flacURL.path)
                {
                    try? FileManager.default.removeItem(at: wavURL)
                    DispatchQueue.main.async { completion(flacURL) }
                    return
                }
            } catch {}

            DispatchQueue.main.async { completion(wavURL) }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }
}
