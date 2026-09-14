import SwiftUI

struct ContentView: View {
    @ObservedObject var model: GroqDictateAppModel
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                List {
                    recordingCard
                        .padding(.top, model.sessions.isEmpty ? 0 : geometry.size.height * 0.10)
                        .frame(minHeight: recorderHeight(in: geometry.size.height))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    if !model.sessions.isEmpty {
                        Section("Recordings") {
                            ForEach(model.sessions) { session in
                                NavigationLink {
                                    SessionDetailView(sessionID: session.id, model: model)
                                } label: {
                                    SessionRow(
                                        session: session,
                                        liveDuration: session.id == model.currentSessionID ? model.elapsed : nil
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollIndicators(.hidden)
                .navigationTitle("GroqDictate")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(model: model)
                }
                .alert(model.errorMessage ?? "Something went wrong", isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { model.errorMessage = nil }
                }
            }
        }
    }

    private func recorderHeight(in availableHeight: CGFloat) -> CGFloat {
        if model.sessions.isEmpty {
            return max(540, availableHeight * 0.78)
        }
        return max(460, availableHeight * 0.68)
    }

    private var recordingCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
                    .frame(width: 150, height: 150)
                Button {
                    model.toggleRecording()
                } label: {
                    Image(systemName: model.presentsActiveControls ? "stop.fill" : "mic.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(model.presentsActiveControls ? Color.red : Color.accentColor)
                        .frame(width: 120, height: 120)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.presentsActiveControls ? "Stop recording" : "Start recording")
            }

            VStack(spacing: 5) {
                Text(statusTitle)
                    .font(.title3.bold())
                if model.presentsActiveControls {
                    Text(model.elapsed.formattedDuration)
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if model.showsResume {
                Button(IOSAppStrings.Recording.resume, systemImage: "mic.fill") {
                    model.resumeIfNeeded()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var statusTitle: String {
        if model.isRecording { return IOSAppStrings.Recording.recording }
        if model.showsResume { return IOSAppStrings.Recording.pausedSafely }
        return IOSAppStrings.Recording.ready
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let liveDuration: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text((liveDuration ?? session.duration).formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch session.state {
        case .recording: return "Recording"
        case .interrupted: return "Paused safely"
        case .processing: return "Transcribing"
        case .complete: return session.transcript
        case .failed:
            if session.pendingCount == 1 { return "1 part ready to retry" }
            if session.pendingCount > 1 { return "\(session.pendingCount) parts ready to retry" }
            return "Ended early · audio saved"
        }
    }

    private var icon: String {
        switch session.state {
        case .recording: return "waveform.circle.fill"
        case .interrupted: return "pause.circle.fill"
        case .processing: return "ellipsis.circle.fill"
        case .complete: return "waveform"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch session.state {
        case .recording: return .red
        case .interrupted: return .orange
        case .processing: return .blue
        case .complete: return .secondary
        case .failed: return .orange
        }
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let value = max(0, Int(self))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
