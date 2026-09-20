import SwiftUI

/// Asks who a voice belongs to, at a moment when there is enough evidence to make the
/// question answerable.
///
/// ## The four answers, and what each one means
/// | Button | Stored as | Effect |
/// |---|---|---|
/// | Save | `.named` | The voice gets a name, everywhere, retroactively. |
/// | Don't know | `.skipped` | Stays "Unknown voice"; Clipper stops asking about it. |
/// | Ask later | `.askLater` | Offered again only once the voice has three times as much audio. |
/// | Close | unchanged | Nothing recorded; it may be offered again. |
///
/// "Don't know" is a real answer, not a dismissal: recording that the user could not
/// identify a voice is information, and it stops the prompt from becoming nagging.
struct SpeakerNamingSheet: View {
    let speaker: SpeakerDTO

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: AudioLibrary
    @EnvironmentObject private var pipeline: PipelineStatus
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var samples: [TranscriptLineDTO] = []
    @State private var isLoading = true
    @FocusState private var nameFocused: Bool

    private let store = ClipperStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(SpeakerPalette.color(for: speaker.colorIndex))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "waveform")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A voice Clipper keeps hearing")
                                .font(.subheadline.weight(.medium))
                            Text("\(ClipperFormat.compactDuration(speaker.totalSpeechSeconds)) across \(speaker.sampleCount) clips")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Clipper groups similar-sounding audio into one voice. It is a rough match, not voice recognition, so it can split one person in two or merge two people — you can fix either in Speakers.")
                }

                Section("Name") {
                    TextField("e.g. Alex", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(save)
                }

                Section("What this voice said") {
                    if isLoading {
                        LoadingPlaceholder(label: "Loading samples")
                    } else if samples.isEmpty {
                        Text("No transcribed samples yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(samples) { line in
                            SampleRow(line: line)
                        }
                    }
                }

                Section {
                    Button("Don't know who this is") {
                        store.detach { await $0.setSpeakerPromptState(id: speaker.id, state: .skipped) }
                        finish()
                    }
                    Button("Ask later") {
                        store.detach { await $0.setSpeakerPromptState(id: speaker.id, state: .askLater) }
                        finish()
                    }
                } footer: {
                    Text("Naming a voice applies to everything it has already said, and to everything it says from now on.")
                }
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { finish() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                name = speaker.displayName ?? ""
                samples = await store.recentLines(speakerID: speaker.id, limit: 5)
                isLoading = false
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.detach { await $0.renameSpeaker(id: speaker.id, to: trimmed) }
        finish()
    }

    private func finish() {
        player.stop()
        pipeline.namingPrompt = nil
        dismiss()
    }
}

/// One sample line, playable when its evidence audio still exists.
private struct SampleRow: View {
    let line: TranscriptLineDTO

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: AudioLibrary

    private var audioURL: URL? {
        guard line.audioAvailable, let id = line.audioSegmentID else { return nil }
        return library.evidenceURL(for: id)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let audioURL {
                Button {
                    player.toggle(url: audioURL, fallbackDuration: line.duration)
                } label: {
                    Image(systemName: player.isPlaying(url: audioURL) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play sample")
            } else {
                Image(systemName: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(line.text)
                    .font(.footnote)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(line.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if audioURL == nil {
                        Text("· audio expired")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Fire-and-forget store writes

extension ClipperStore {
    /// Run a mutation without making the caller `await` it.
    ///
    /// Views use this for user actions where the UI has already moved on — renaming a
    /// speaker, archiving a memory. The actor still serialises the write; the view simply
    /// does not block on it.
    nonisolated func detach(_ work: @escaping (ClipperStore) async -> Void) {
        Task.detached(priority: .userInitiated) { await work(self) }
    }
}
