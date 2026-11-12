import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID
    @ObservedObject var model: GroqDictateAppModel
    @State private var audioURLs: [UUID: URL] = [:]
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
                        ForEach(session.segments.sorted { $0.index < $1.index }) { segment in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(audioTitle(for: segment, in: session))
                                        if let status = segment.state.visibleDisplayName {
                                            Text(status)
                                                .font(.caption)
                                                .foregroundStyle(segment.state.needsAttention ? .orange : .secondary)
                                        }
                                    }
                                    if segment.state != .unavailable, let error = segment.lastError {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if segment.state != .unavailable, let url = audioURLs[segment.id] {
                                    ShareLink(item: url) {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                    .accessibilityLabel("Share \(audioTitle(for: segment, in: session))")
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
                    var values: [UUID: URL] = [:]
                    for segment in session.segments where segment.state != .unavailable {
                        guard await model.hasAudio(sessionID: session.id, fileName: segment.fileName) else { continue }
                        values[segment.id] = model.audioURL(sessionID: session.id, fileName: segment.fileName)
                    }
                    audioURLs = values
                }
            } else {
                ContentUnavailableView("Recording unavailable", systemImage: "waveform.slash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func audioTitle(
        for segment: RecordingSession.Segment,
        in session: RecordingSession
    ) -> String {
        session.segments.count == 1 ? "Original audio" : "Part \(segment.index + 1)"
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
