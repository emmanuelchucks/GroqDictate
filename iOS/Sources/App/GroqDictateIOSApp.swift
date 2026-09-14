import SwiftUI

@main
struct GroqDictateIOSApp: App {
    @StateObject private var model = GroqDictateAppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        TimingDiagnostics.shared.record(.launch)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.prepareForVisibleApp() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: TimingDiagnostics.shared.record(.active)
            case .inactive: TimingDiagnostics.shared.record(.inactive)
            case .background: TimingDiagnostics.shared.record(.background)
            @unknown default: break
            }
            if phase == .active {
                Task { await model.prepareForVisibleApp() }
                model.resumeIfNeeded()
            }
        }
    }
}
