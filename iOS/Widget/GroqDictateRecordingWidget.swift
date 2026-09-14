import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GroqDictateRecordingWidgets: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 18.0, *) {
            GroqDictateRecordingControl()
        }
        GroqDictateRecordingActivity()
    }
}

@available(iOSApplicationExtension 18.0, *)
struct GroqDictateRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "GroqDictateRecordingControl") {
            ControlWidgetButton(action: ToggleGroqRecordingIntent()) {
                Label("GroqDictate", systemImage: "mic.fill")
            }
        }
        .displayName("GroqDictate Recording")
        .description("Start or stop a retained GroqDictate recording.")
    }
}

struct GroqDictateRecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GroqRecordingAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                Text("GroqDictate recording")
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("GroqDictate recording")
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "mic.fill")
            }
        }
    }
}
