import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var model: GroqDictateAppModel
    @State private var audioURLs: [String: URL] = [:]
    @State private var copiedTranscript = false
    @State private var copiedOriginal = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var session: RecordingSession? { model.session(id: sessionID) }

    var body: some View {
        Group {
            if let session {
                List {
                    Section("Transcript") {
                        if session.transcript.isEmpty {
                            Text(emptyTranscriptText(for: session))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.text(of: session))
                                .textSelection(.enabled)
                            Button(
                                copiedTranscript ? "Copied" : "Copy transcript",
                                systemImage: copiedTranscript ? "checkmark" : "doc.on.doc"
                            ) {
                                model.copyTranscript(session)
                                copiedTranscript = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    copiedTranscript = false
                                }
                            }
                        }
                        if session.originalTranscript != nil {
                            Button(
                                copiedOriginal ? "Copied" : "Copy original",
                                systemImage: copiedOriginal ? "checkmark" : "text.badge.plus"
                            ) {
                                model.copyOriginalTranscript(session)
                                copiedOriginal = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    copiedOriginal = false
                                }
                            }
                            Text("Groq's text, with phantom phrases left in.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Audio") {
                        let takes = Take.all(in: session)
                        ForEach(Array(takes.enumerated()), id: \.element.fileName) { number, take in
                            let title = takes.count == 1 ? "Original audio" : "Audio \(number + 1)"
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(title)
                                        if let status = take.state.visibleDisplayName {
                                            Text(status)
                                                .font(.caption)
                                                .foregroundStyle(take.state.needsAttention ? .orange : .secondary)
                                        }
                                    }
                                    if take.state != .unavailable, let error = take.lastError {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if take.state != .unavailable, let url = audioURLs[take.fileName] {
                                    ShareLink(item: url) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    .accessibilityLabel("Share \(title)")
                                }
                            }
                        }
                    }

                    if model.canRetry(session) {
                        Button(IOSAppStrings.Transcription.retry, systemImage: "arrow.clockwise") {
                            model.retry(session.id)
                        }
                    }
                }
                .navigationTitle(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                .toolbar {
                    if model.canDelete(session) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(IOSAppStrings.Recording.delete, systemImage: "trash") { confirmingDelete = true }
                        }
                    }
                }
                .confirmationDialog(
                    IOSAppStrings.Recording.deleteTitle,
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button(IOSAppStrings.Recording.delete, role: .destructive) {
                        dismiss()
                        Task { await model.delete(sessionID) }
                    }
                } message: {
                    Text(IOSAppStrings.Recording.deleteMessage)
                }
                .task(id: session.updatedAt) {
                    var values: [String: URL] = [:]
                    for fileName in Set(session.segments.map(\.fileName)) {
                        guard await model.hasAudio(sessionID: session.id, fileName: fileName) else { continue }
                        values[fileName] = model.audioURL(sessionID: session.id, fileName: fileName)
                    }
                    audioURLs = values
                }
            } else {
                ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func emptyTranscriptText(for session: RecordingSession) -> String {
        switch session.state {
        case .recording, .interrupted, .processing:
            return "Transcript pending."
        case .complete:
            return "No speech detected."
        case .failed:
            return "No transcript available."
        }
    }
}

/// One audio file and the parts in it: a take, or a single part of an
/// older recording.
private struct Take {
    let fileName: String
    let parts: [RecordingSession.Segment]

    static func all(in session: RecordingSession) -> [Take] {
        let parts = session.segments.sorted { $0.index < $1.index }
        var names: [String] = []
        for part in parts where !names.contains(part.fileName) { names.append(part.fileName) }
        return names.map { name in Take(fileName: name, parts: parts.filter { $0.fileName == name }) }
    }

    /// The state that most needs the user's attention. A take is "Not
    /// recorded" only when none of it was.
    var state: RecordingSession.Segment.State {
        if parts.allSatisfy({ $0.state == .unavailable }) { return .unavailable }
        let order: [RecordingSession.Segment.State] = [.failed, .unavailable, .transcribing, .pending, .recording, .complete]
        return order.first { state in parts.contains { $0.state == state } } ?? .complete
    }

    var lastError: String? {
        parts.first { $0.state == .failed || $0.state == .unavailable }?.lastError
    }
}

private extension RecordingSession.Segment.State {
    var visibleDisplayName: String? {
        switch self {
        case .recording: return "Recording"
        case .pending: return "Pending"
        case .transcribing: return "Transcribing"
        case .complete: return nil
        case .failed: return "Retry needed"
        case .unavailable: return "Not recorded"
        }
    }

    var needsAttention: Bool {
        self == .failed || self == .unavailable
    }
}
