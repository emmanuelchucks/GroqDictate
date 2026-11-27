import SwiftUI
import UIKit
import UserNotifications

@main
struct GroqDictateIOSApp: App {
    @StateObject private var model = GroqDictateAppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TimingDiagnostics.shared.record(.launch)
        UNUserNotificationCenter.current().delegate = TranscriptNotifications.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.prepareForVisibleApp() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    model.appDidBecomeActive()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                TimingDiagnostics.shared.record(.active)
            case .inactive:
                TimingDiagnostics.shared.record(.inactive)
            case .background:
                TimingDiagnostics.shared.record(.background)
                model.appDidEnterBackground()
            @unknown default:
                break
            }
        }
    }
}

/// iOS asks the app whether to show its own notification while the app
/// still counts as in front (for a moment after the user switches away),
/// and shows nothing unless told to. Skip if the app is already active again.
final class TranscriptNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TranscriptNotifications()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        return isActive ? [] : [.banner, .list, .sound]
    }
}
