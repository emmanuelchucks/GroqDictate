import AVFoundation
import ApplicationServices
import Foundation

final class PermissionService {
    enum MicrophoneStatus: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
        case unknown
    }

    enum AccessibilityStatus: Equatable {
        case trusted
        case notTrusted
    }

    enum EventAccessStatus: Equatable {
        case granted
        case denied
        case unavailable
    }

    enum GuidanceAction: Equatable, Hashable {
        case accessibilityDenied
        case inputMonitoringDenied
        case postEventDenied
    }

    struct Snapshot: Equatable {
        let microphone: MicrophoneStatus
        let accessibility: AccessibilityStatus
        let listenEvent: EventAccessStatus
        let postEvent: EventAccessStatus
    }

    static let shared = PermissionService()

    private init() {}

    func preflight() -> Snapshot {
        Snapshot(
            microphone: preflightMicrophone(),
            accessibility: preflightAccessibility(),
            listenEvent: preflightListenEventAccess(),
            postEvent: preflightPostEventAccess()
        )
    }

    static func guidanceActions(for snapshot: Snapshot) -> [GuidanceAction] {
        var actions: [GuidanceAction] = []

        if snapshot.accessibility == .notTrusted {
            actions.append(.accessibilityDenied)
        }

        if snapshot.listenEvent == .denied {
            actions.append(.inputMonitoringDenied)
        }

        return actions
    }

    func preflightMicrophone() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    func requestMicrophoneAccess(completion: @escaping (MicrophoneStatus) -> Void) {
        let status = preflightMicrophone()
        guard status == .notDetermined else {
            completion(status)
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            completion(self?.preflightMicrophone() ?? .unknown)
        }
    }

    func preflightAccessibility() -> AccessibilityStatus {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    @discardableResult
    func requestAccessibilityAccess(prompt: Bool = true) -> AccessibilityStatus {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        return preflightAccessibility()
    }

    func preflightListenEventAccess() -> EventAccessStatus {
        guard #available(macOS 10.15, *) else { return .unavailable }
        return CGPreflightListenEventAccess() ? .granted : .denied
    }

    @discardableResult
    func requestListenEventAccess() -> EventAccessStatus {
        guard #available(macOS 10.15, *) else { return .unavailable }
        return CGRequestListenEventAccess() ? .granted : .denied
    }

    func preflightPostEventAccess() -> EventAccessStatus {
        guard #available(macOS 10.15, *) else { return .unavailable }
        return CGPreflightPostEventAccess() ? .granted : .denied
    }

    @discardableResult
    func requestPostEventAccess() -> EventAccessStatus {
        guard #available(macOS 10.15, *) else { return .unavailable }
        return CGRequestPostEventAccess() ? .granted : .denied
    }
}
