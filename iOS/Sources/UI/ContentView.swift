import SwiftUI

struct ContentView: View {
    @ObservedObject var model: GroqDictateAppModel
    @State private var showingSettings = false
    @State private var sessionToDelete: RecordingSession?

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
                                        text: model.text(of: session),
                                        liveDuration: session.id == model.currentSessionID ? model.elapsed : nil,
                                        isOnClipboard: model.isOnClipboard(session.id)
                                    )
                                }
                                .swipeActions {
                                    if model.canDelete(session) {
                                        // Not role: .destructive, which removes the row before the confirmation.
                                        Button("Delete", systemImage: "trash") { sessionToDelete = session }
                                            .tint(.red)
                                    }
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
                .confirmationDialog(
                    IOSAppStrings.Recording.deleteTitle,
                    isPresented: Binding(
                        get: { sessionToDelete != nil },
                        set: { if !$0 { sessionToDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: sessionToDelete
                ) { session in
                    Button(IOSAppStrings.Recording.delete, role: .destructive) {
                        Task { await model.delete(session.id) }
                    }
                } message: { _ in
                    Text(IOSAppStrings.Recording.deleteMessage)
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
                    .fill(buttonTint.opacity(model.lifecycle == .interrupted ? 0.07 : 0.12))
                    .frame(width: 150, height: 150)
                Button {
                    model.toggleRecording()
                } label: {
                    Image(systemName: showsStop ? "stop.fill" : "mic.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(buttonTint)
                        .frame(width: 120, height: 120)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsStop ? "Stop recording" : "Start recording")
            }

            VStack(spacing: 5) {
                Label {
                    Text(status.title)
                } icon: {
                    if let icon = status.icon {
                        Image(systemName: icon).foregroundStyle(status.iconColor)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.title3.bold())
                // Fixed heights keep the card still between states.
                Text(status.detail ?? " ")
                    .font(status.detailIsDuration
                        ? .system(.title2, design: .monospaced).weight(.medium)
                        : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 34)
                    .accessibilityHidden(status.detail == nil)
            }

            actionRow
                .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // A ZStack, not a bare @ViewBuilder: frames on an empty branch take no
    // space, which made the card move.
    private var actionRow: some View {
        ZStack {
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.lifecycle.showsResume {
            // A Label's icon in a List row takes the accent tint, which vanishes
            // on an accent-filled button, so the icon is coloured explicitly.
            Button {
                model.resume()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(IOSAppStrings.Recording.resume)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
        } else if let session = model.stoppedSession, session.state == .failed, model.canRetry(session) {
            Button(IOSAppStrings.Transcription.retry, systemImage: "arrow.clockwise") {
                model.retry(session.id)
            }
            .buttonStyle(.bordered)
        }
    }

    private var showsStop: Bool { model.lifecycle.presentsActiveControls }


    private var buttonTint: Color { showsStop ? .red : .accentColor }

    private struct Status {
        var title: String
        var icon: String?
        var iconColor: Color = .secondary
        var detail: String?
        var detailIsDuration = false
    }

    private var status: Status {
        let timer = model.elapsed.formattedDuration
        switch model.lifecycle {
        case .recording:
            return Status(title: IOSAppStrings.Recording.recording, detail: timer, detailIsDuration: true)
        case .interrupted:
            return Status(title: IOSAppStrings.Recording.paused, icon: "pause.circle.fill",
                          iconColor: .orange, detail: timer, detailIsDuration: true)
        case .resuming:
            return Status(title: IOSAppStrings.Recording.resuming, detail: timer, detailIsDuration: true)
        case .starting, .stopping, .idle:
            break
        }
        // A normal transcription takes a second or two and shows nothing;
        // only a slow one says so.
        guard let session = model.stoppedSession else { return Status(title: IOSAppStrings.Recording.ready) }
        let duration = session.duration.formattedDuration
        switch session.state {
        case .processing, .recording, .interrupted:
            guard model.slowSessionID == session.id else { return Status(title: IOSAppStrings.Recording.ready) }
            return Status(title: IOSAppStrings.Recording.transcribing, detail: duration,
                          detailIsDuration: true)
        case .complete where session.transcript.isEmpty:
            return Status(title: IOSAppStrings.Errors.noSpeechDetected, detail: duration, detailIsDuration: true)
        case .complete:
            return Status(title: model.copiedSessionID == session.id ? IOSAppStrings.Recording.copied : IOSAppStrings.Recording.ready,
                          icon: model.copiedSessionID == session.id ? "checkmark.circle.fill" : nil,
                          iconColor: .green, detail: duration, detailIsDuration: true)
        case .failed:
            let reason = session.segments.first { $0.state == .failed }?.lastError
            return Status(title: IOSAppStrings.Recording.notTranscribed, icon: "exclamationmark.circle.fill",
                          iconColor: .orange, detail: reason ?? duration, detailIsDuration: reason == nil)
        }
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let text: String
    let liveDuration: TimeInterval?
    let isOnClipboard: Bool

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
        case .complete: return text.isEmpty ? IOSAppStrings.Errors.noSpeechDetected : text
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
        case .processing: return "waveform"
        case .complete: return isOnClipboard ? "doc.on.clipboard" : "waveform"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch session.state {
        case .recording: return .red
        case .interrupted: return .orange
        case .processing: return .secondary
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
