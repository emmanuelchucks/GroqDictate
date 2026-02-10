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

    // Threshold: only convert to FLAC if WAV exceeds this size (saves time for short recordings)
    // Groq docs: "For lower latency, convert your files to wav format"
    // So WAV is actually faster for Groq to process — FLAC only helps reduce upload time for large files
    private static let flacThresholdBytes = 5 * 1024 * 1024  // 5MB ≈ 2.5 min of 16kHz mono

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

            let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self).pointee
            let totalChannels = (0..<Int(bufferList.mNumberBuffers)).reduce(0) { total, _ in
                total + Int(bufferList.mBuffers.mNumberChannels)
            }
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

    // MARK: - Recording

    func start(levelHandler: @escaping (Float) -> Void) throws {
        levelCallback = levelHandler

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Record as 16-bit PCM (half the size of float32, sufficient for speech)
        let recordFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

        try? FileManager.default.removeItem(at: wavURL)
        audioFile = try AVAudioFile(forWriting: wavURL, settings: recordFormat.settings)

        // Intermediate float format for gain/RMS computation
        let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let toFloat = AVAudioConverter(from: hwFormat, to: floatFormat)!
        let toInt16 = AVAudioConverter(from: floatFormat, to: recordFormat)!
        let gain = inputGain

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate)
            guard frameCount > 0 else { return }

            // Convert to float for gain + RMS
            guard
                let floatBuffer = AVAudioPCMBuffer(
                    pcmFormat: floatFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            toFloat.convert(to: floatBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            // Apply gain and compute RMS
            if let channelData = floatBuffer.floatChannelData {
                let count = Int(floatBuffer.frameLength)
                var sum: Float = 0
                for i in 0..<count {
                    if gain > 1.0 { channelData[0][i] *= gain }
                    sum += channelData[0][i] * channelData[0][i]
                }
                self.currentLevel = min(sqrt(sum / Float(count)) * 3.0, 1.0)
            }

            // Convert to 16-bit PCM for smaller WAV
            guard
                let int16Buffer = AVAudioPCMBuffer(
                    pcmFormat: recordFormat, frameCapacity: frameCount)
            else { return }

            toInt16.convert(to: int16Buffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return floatBuffer
            }

            // Write to file on background queue
            self.writeQueue.async { [weak self] in
                try? self?.audioFile?.write(from: int16Buffer)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.levelCallback?(self.currentLevel)
        }
    }

    /// Stop recording. For short recordings, returns the WAV directly (Groq processes WAV faster).
    /// For longer recordings, compresses to FLAC using macOS-native afconvert (zero dependencies).
    func stop(completion: @escaping (URL) -> Void) {
        levelTimer?.invalidate()
        levelTimer = nil
        levelCallback = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Ensure pending writes finish before reading the file
        writeQueue.sync {
            self.audioFile = nil
        }

        // Check file size to decide if FLAC conversion is worth it
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0

        if fileSize < Self.flacThresholdBytes {
            // Short recording — WAV is fine, skip conversion overhead
            DispatchQueue.main.async { completion(self.wavURL) }
            return
        }

        // Longer recording — compress with macOS-native afconvert (ships with every Mac)
        DispatchQueue.global(qos: .userInitiated).async { [wavURL, flacURL] in
            try? FileManager.default.removeItem(at: flacURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = [
                "-f", "flac",  // FLAC container
                "-d", "flac",  // FLAC codec
                "-c", "1",  // mono
                wavURL.path,
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
}
