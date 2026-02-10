import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let wavURL: URL
    private let flacURL: URL
    private var levelCallback: ((Float) -> Void)?
    private var levelTimer: Timer?

    /// Current audio input power level (0.0 to 1.0)
    private(set) var currentLevel: Float = 0

    /// Gain multiplier for the input signal
    var inputGain: Float = 2.5

    init() {
        let tmp = NSTemporaryDirectory()
        let pid = ProcessInfo.processInfo.processIdentifier
        wavURL = URL(fileURLWithPath: tmp).appendingPathComponent("groq-\(pid).wav")
        flacURL = URL(fileURLWithPath: tmp).appendingPathComponent("groq-\(pid).flac")
    }

    func start(onLevel: @escaping (Float) -> Void) throws {
        levelCallback = onLevel
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        audioFile = try AVAudioFile(forWriting: wavURL, settings: targetSettings)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            // Calculate RMS level from raw buffer with gain applied
            if let channelData = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[i] * self.inputGain
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(max(frames, 1)))
                self.currentLevel = min(rms * 3.0, 1.0)
            }

            // Apply gain before conversion
            if let channelData = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                for ch in 0..<Int(inputFormat.channelCount) {
                    for i in 0..<frames {
                        channelData[ch][i] *= self.inputGain
                    }
                }
            }

            // Convert to 16kHz mono and write
            let ratio = 16000.0 / inputFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard frameCount > 0,
                let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil {
                try? audioFile.write(from: converted)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Push level updates at 30fps on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                self.levelCallback?(self.currentLevel)
            }
        }
    }

    /// Stop recording and return a FLAC-compressed file URL for fast upload.
    /// Strips silence and compresses to FLAC in one ffmpeg pass.
    func stop() -> URL {
        levelTimer?.invalidate()
        levelTimer = nil
        levelCallback = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioFile = nil

        // Convert WAV → FLAC with silence removal in one pass
        // silenceremove: strip leading silence, then compress internal silences
        //   stop_periods=-1 = process entire file (not just leading)
        //   stop_threshold=-40dB = anything below -40dB is "silence"
        //   stop_duration=0.3 = silence must be >0.3s to be removed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-y", "-i", wavURL.path,
            "-af",
            "silenceremove=stop_periods=-1:stop_duration=0.3:stop_threshold=-40dB",
            "-ar", "16000", "-ac", "1", "-c:a", "flac",
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
                return flacURL
            }
        } catch {}

        // Fallback to WAV if ffmpeg isn't available
        return wavURL
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: flacURL)
    }

    /// List available audio input devices using CoreAudio
    static func availableInputDevices() -> [(uid: String, name: String)] {
        var results: [(uid: String, name: String)] = []

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

        for device in devices {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard
                AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize) == noErr,
                inputSize > 0
            else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard
                AudioObjectGetPropertyData(
                    device, &inputAddress, 0, nil, &inputSize, bufferListPtr) == noErr
            else { continue }
            if bufferListPtr.pointee.mBuffers.mNumberChannels == 0 { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &cfUID)

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName)

            results.append((uid: cfUID as String, name: cfName as String))
        }
        return results
    }

    enum RecorderError: LocalizedError {
        case formatCreationFailed
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .formatCreationFailed: return "Failed to create target audio format"
            case .converterCreationFailed: return "Failed to create audio converter"
            }
        }
    }
}
