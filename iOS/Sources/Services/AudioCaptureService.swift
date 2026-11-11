import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService: NSObject {
    enum InterruptionEvent: Equatable {
        case began
        case routeLost
        case ended(shouldResume: Bool)
    }

    enum CaptureError: LocalizedError {
        case permissionDenied
        case couldNotActivate(code: Int)
        case couldNotStart

        var code: Int? {
            if case .couldNotActivate(let code) = self { return code }
            return nil
        }

        /// iOS refuses the mic while a call or another higher-priority app holds
        /// it; after a call ends in the background it can also say it can't
        /// start recording (developer.apple.com/forums/thread/120038).
        var isMicrophoneBusy: Bool {
            guard let code, let reason = AVAudioSession.ErrorCode(rawValue: code) else { return false }
            return [.insufficientPriority, .cannotInterruptOthers, .cannotStartRecording].contains(reason)
        }

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access is required"
            case .couldNotActivate where isMicrophoneBusy: return "The mic is in use, for example by a call"
            case .couldNotActivate, .couldNotStart: return "Recording could not start"
            }
        }
    }

    var onInterruption: ((InterruptionEvent) -> Void)?
    private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private let audioSession = AVAudioSession.sharedInstance()
    private let recorderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(fileURL: URL) throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.permissionDenied
        }

        // mixWithOthers is supported with playAndRecord, not record. This
        // preserves capture while avoiding unnecessary interruption of audio
        // already playing on the device.
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )
        try? audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)

        // record() would activate the session too, but only reports a Bool;
        // activating here surfaces iOS's reason when it refuses.
        do {
            try audioSession.setActive(true)
        } catch {
            throw CaptureError.couldNotActivate(code: (error as NSError).code)
        }
        let recorder = try makeRecorder(fileURL: fileURL)
        guard recorder.record() else { throw CaptureError.couldNotStart }
        self.recorder = recorder
        isRecording = true
    }

    func rotate(fileURL: URL) throws {
        guard let currentRecorder = recorder, isRecording else {
            throw CaptureError.couldNotStart
        }

        // Prepare the next file while the current recorder and background audio
        // session remain active, then swap synchronously without deactivation.
        let nextRecorder = try makeRecorder(fileURL: fileURL)
        currentRecorder.stop()
        guard nextRecorder.record() else {
            recorder = nil
            isRecording = false
            throw CaptureError.couldNotStart
        }
        recorder = nextRecorder
        isRecording = true
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func makeRecorder(fileURL: URL) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(url: fileURL, settings: recorderSettings)
        recorder.prepareToRecord()
        return recorder
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor [weak self] in
            self?.processInterruption(type: rawType, options: rawOptions)
        }
    }

    private func processInterruption(type rawType: UInt, options rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            recorder?.stop()
            recorder = nil
            isRecording = false
            onInterruption?(.began)
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            onInterruption?(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        Task { @MainActor [weak self] in
            self?.processRouteChange(reason: rawReason)
        }
    }

    private func processRouteChange(reason rawReason: UInt) {
        guard isRecording,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return }
        stop()
        onInterruption?(.routeLost)
    }
}
