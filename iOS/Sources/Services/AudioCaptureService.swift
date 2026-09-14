import AVFoundation
import Foundation

@MainActor
final class AudioCaptureService: NSObject {
    enum InterruptionEvent {
        case began
        case ended(shouldResume: Bool)
    }

    enum CaptureError: LocalizedError {
        case permissionDenied
        case couldNotStart

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access is required"
            case .couldNotStart: return "Recording could not start"
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

        // This exact mixable recording configuration is required for a cold
        // AudioRecordingIntent start while another app remains foregrounded.
        try audioSession.setCategory(
            .record,
            mode: .default,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )
        try? audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)

        // Do not explicitly activate here. AudioRecordingIntent is allowed to
        // start AVAudioRecorder while the containing app is in the background,
        // but AVAudioSession.setActive(true) is rejected there with
        // cannotInterruptOthers. AVAudioRecorder performs the supported
        // implicit activation when record() begins.
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

    @objc private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            recorder?.stop()
            recorder = nil
            isRecording = false
            onInterruption?(.began)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            onInterruption?(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard isRecording,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return }
        stop()
        onInterruption?(.began)
    }
}
