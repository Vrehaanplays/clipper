import SwiftUI

/// Voices, and the tools to fix Clipper's guesses about them.
///
/// The merge action is here because the clustering *will* split one person across two
/// clusters — that is a known limit of matching on timbre alone, stated plainly in the
/// footer rather than hidden. Merging is the user's repair for it, and it repoints every
/// affected transcript line.
struct SpeakerManagerView: View {
    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var speakers: [SpeakerDTO] = []
    @State private var isLoading = true
    @State private var mergeSource: SpeakerDTO?
    @State private var renaming: SpeakerDTO?

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                if isLoading {
                    LoadingPlaceholder()
                } else if speakers.isEmpty {
                    ContentUnavailableView {
                        Label("No voices yet", systemImage: "person.wave.2")
                    } description: {
                        Text("Clipper groups speech by how the voice sounds. Groups appear once it has heard enough.")
                    }
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(speakers) { speaker in
                        NavigationLink {
                            SpeakerDetailView(speakerID: speaker.id)
                        } label: {
                            SpeakerRow(speaker: speaker)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                renaming = speaker
                            } label: {
                                Label("Name", systemImage: "pencil")
                            }
                            .tint(.accentColor)

                            Button {
                                mergeSource = speaker
                            } label: {
                                Label("Merge", systemImage: "arrow.triangle.merge")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("Matching is based on how a voice sounds, not on who it is. It can split one person into two groups or merge two people into one — naming and merging are how you correct it, and both apply retroactively.")
            }

            AwaitingNamesSection(speakers: pipeline.speakersAwaitingNames) { speaker in
                pipeline.namingPrompt = speaker
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Voices")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { speaker in
            SpeakerNamingSheet(speaker: speaker)
        }
        .sheet(item: $mergeSource) { speaker in
            SpeakerMergeSheet(source: speaker,
                              candidates: speakers.filter { $0.id != speaker.id }) {
                await load()
            }
        }
        .task { await load() }
        .onChange(of: pipeline.revision) { _, _ in Task { await load() } }
    }

    private func load() async {
        speakers = await store.speakers()
        isLoading = false
    }
}

/// Its own view rather than an inline branch, with the row split out again: the section
/// used to live inside `SpeakerManagerView.body`, which had grown big enough that the
/// type checker gave up on `ForEach` and reported a misleading overload mismatch. Each
/// piece here is small enough to check on its own.
private struct AwaitingNamesSection: View {
    let speakers: [SpeakerDTO]
    let onTap: (SpeakerDTO) -> Void

    @ViewBuilder
    var body: some View {
        if !speakers.isEmpty {
            Section("Waiting to be named") {
                ForEach(speakers) { (speaker: SpeakerDTO) in
                    AwaitingNameRow(speaker: speaker, onTap: onTap)
                }
            }
        }
    }
}

private struct AwaitingNameRow: View {
    let speaker: SpeakerDTO
    let onTap: (SpeakerDTO) -> Void

    var body: some View {
        Button {
            onTap(speaker)
        } label: {
            HStack {
                SpeakerRow(speaker: speaker)
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SpeakerRow: View {
    let speaker: SpeakerDTO

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(speaker.isNamed ? SpeakerPalette.color(for: speaker.colorIndex) : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: speaker.isNamed ? "person.fill" : "questionmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.label)
                    .font(.subheadline.weight(speaker.isNamed ? .medium : .regular))
                    .foregroundStyle(speaker.isNamed ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(ClipperFormat.compactDuration(speaker.totalSpeechSeconds))
                    Text("·")
                    Text("\(speaker.sampleCount) clip\(speaker.sampleCount == 1 ? "" : "s")")
                    if speaker.promptState == .skipped && !speaker.isNamed {
                        Text("· not asking again")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int((speaker.identityConfidence * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                ScoreBar(value: speaker.identityConfidence,
                         tint: speaker.identityConfidence < 0.5 ? .orange : .green,
                         width: 30)
            }
        }
    }
}

// MARK: - Detail

struct SpeakerDetailView: View {
    let speakerID: UUID

    @State private var speaker: SpeakerDTO?
    @State private var lines: [TranscriptLineDTO] = []
    @State private var conversations: [ConversationDTO] = []
    @State private var isLoading = true
    @State private var renaming = false

    private let store = ClipperStore.shared

    var body: some View {
        List {
            if isLoading {
                LoadingPlaceholder()
            } else if let speaker {
                Section {
                    SpeakerRow(speaker: speaker)
                    if !speaker.previousNames.isEmpty {
                        DetailRow(label: "Previously called",
                                  value: speaker.previousNames.joined(separator: ", "),
                                  systemImage: "clock.arrow.circlepath")
                    }
                    DetailRow(label: "First heard",
                              value: speaker.createdAt.formatted(date: .abbreviated, time: .shortened),
                              systemImage: "calendar")
                    Button {
                        renaming = true
                    } label: {
                        Label(speaker.isNamed ? "Rename" : "Name this voice", systemImage: "pencil")
                    }
                } footer: {
                    Text("Confidence here is how much evidence the grouping rests on, not how sure Clipper is of the name.")
                }

                Section("Conversations") {
                    if conversations.isEmpty {
                        Text("No conversations recorded for this voice.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conversations) { conversation in
                            NavigationLink {
                                ConversationDetailView(conversationID: conversation.id)
                            } label: {
                                ConversationRow(conversation: conversation)
                            }
                        }
                    }
                }

                Section("Recent lines") {
                    ForEach(lines) { line in
                        NavigationLink {
                            EvidenceDetailView(line: line, conversation: nil, summary: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.text).font(.footnote).lineLimit(3)
                                Text(line.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Voice not found", systemImage: "person.slash")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(speaker?.label ?? "Voice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $renaming) {
            if let speaker { SpeakerNamingSheet(speaker: speaker) }
        }
        .task { await load() }
    }

    private func load() async {
        speaker = await store.speaker(id: speakerID)
        lines = await store.recentLines(speakerID: speakerID, limit: 20)
        conversations = await store.conversations(speakerID: speakerID, limit: 20)
        isLoading = false
    }
}

// MARK: - Merge

struct SpeakerMergeSheet: View {
    let source: SpeakerDTO
    let candidates: [SpeakerDTO]
    let onMerge: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: UUID?

    private let store = ClipperStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SpeakerRow(speaker: source)
                } header: {
                    Text("Merge this voice")
                }

                Section {
                    if candidates.isEmpty {
                        Text("There is no other voice to merge into.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Into", selection: $target) {
                            Text("Choose").tag(UUID?.none)
                            ForEach(candidates) { candidate in
                                Text(candidate.label).tag(Optional(candidate.id))
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } header: {
                    Text("Into")
                } footer: {
                    Text("Every line attributed to \(source.label) moves to the voice you pick, and the two audio profiles are blended. This cannot be undone automatically, but you can always reassign individual lines.")
                }
            }
            .navigationTitle("Merge voices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Merge") {
                        guard let target else { return }
                        dismiss()
                        Task.detached(priority: .userInitiated) {
                            await store.mergeSpeakers(keep: target, absorb: source.id)
                            await onMerge()
                        }
                    }
                    .disabled(target == nil)
                }
            }
        }
    }
}

// MARK: - Session history

struct SessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionDTO] = []
    @State private var isLoading = true
    @State private var canLoadMore = true

    private let pageSize = 40
    private let store = ClipperStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading && sessions.isEmpty {
                        LoadingPlaceholder()
                    } else if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("No sessions yet", systemImage: "mic.slash")
                        } description: {
                            Text("Every time you start listening, a session is recorded here.")
                        }
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                        }
                        if canLoadMore {
                            Button("Load more") { Task { await loadPage() } }
                                .font(.subheadline)
                        }
                    }
                } footer: {
                    Text("Session rows are tiny and never deleted, so \u{201C}was Clipper listening then?\u{201D} stays answerable long after the audio is gone.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadPage() }
        }
    }

    private func loadPage() async {
        let page = await store.sessions(limit: pageSize, offset: sessions.count)
        sessions.append(contentsOf: page)
        canLoadMore = page.count == pageSize
        isLoading = false
    }
}
