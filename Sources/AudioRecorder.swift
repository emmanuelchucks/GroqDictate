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

    private var levelTimer: Timer?
    private var levelCallback: ((Float) -> Void)?
    private var currentLevel: Float = 0

    // Serial queue for file writes (keep I/O off the audio thread)
    private let writeQueue = DispatchQueue(label: "com.groqdictate.audiowrite")

    // Cached ffmpeg path (resolved once)
    private static let ffmpegPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",  // Intel Homebrew
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

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
            // Check if device has input channels
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

            // Allocate based on actual data size to handle variable-length AudioBufferList
            let bufferListPtr = UnsafeMutableRawPointer.allocate(
                byteCount: Int(chanSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { bufferListPtr.deallocate() }

            guard
                AudioObjectGetPropertyData(
                    device, &inputChannels, 0, nil, &chanSize, bufferListPtr) == noErr
            else { continue }

            let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self).pointee
            let totalChannels = (0..<Int(bufferList.mNumberBuffers)).reduce(0) { total, _ in
                total + Int(bufferList.mBuffers.mNumberChannels)
            }
            guard totalChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName)

            // Get device UID
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

    // MARK: - Recording

    func start(levelHandler: @escaping (Float) -> Void) throws {
        levelCallback = levelHandler

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        try? FileManager.default.removeItem(at: wavURL)
        audioFile = try AVAudioFile(forWriting: wavURL, settings: recordFormat.settings)

        let converter = AVAudioConverter(from: hwFormat, to: recordFormat)!
        let gain = inputGain

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate)
            guard
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: recordFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            // Apply gain and compute RMS on the audio thread (lightweight)
            if gain > 1.0, let channelData = convertedBuffer.floatChannelData {
                let count = Int(convertedBuffer.frameLength)
                var sum: Float = 0
                for i in 0..<count {
                    channelData[0][i] *= gain
                    sum += channelData[0][i] * channelData[0][i]
                }
                self.currentLevel = min(sqrt(sum / Float(count)) * 3.0, 1.0)
            } else {
                self.currentLevel = self.computeRMS(convertedBuffer)
            }

            // File write dispatched off the audio thread
            self.writeQueue.async { [weak self] in
                try? self?.audioFile?.write(from: convertedBuffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Level meter fires at 30fps for waveform display
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.levelCallback?(self.currentLevel)
        }
    }

    /// Stop recording, convert WAV→FLAC with silence removal.
    /// Calls completion on main thread with the output file URL.
    func stop(completion: @escaping (URL) -> Void) {
        levelTimer?.invalidate()
        levelTimer = nil
        levelCallback = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil

        guard let ffmpeg = Self.ffmpegPath else {
            // No ffmpeg — use raw WAV
            DispatchQueue.main.async { completion(self.wavURL) }
            return
        }

        // Run ffmpeg async to avoid blocking the main thread
        DispatchQueue.global(qos: .userInitiated).async { [wavURL, flacURL] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-y", "-i", wavURL.path,
                "-af",
                "silenceremove=stop_periods=-1:stop_duration=0.3:stop_threshold=-40dB",
                "-ar", "16000", "-ac", "1", "-c:a", "flac",
                "-threads", "0",
                flacURL.path,
            ]
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

            // Fallback to WAV
            DispatchQueue.main.async { completion(wavURL) }
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channelData[0][i] * channelData[0][i] }
        return min(sqrt(sum / Float(count)) * 3.0, 1.0)
    }
}
