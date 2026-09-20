import UIKit
import SwiftUI

/// The transcript viewer.
///
/// Every line shows who said it (or says plainly that it does not know), how confident the
/// recogniser was, and whether the audio behind it still exists. Corrections are first-class
/// — a wrong speaker or a misheard word is expected, and fixing one updates everything
/// derived from it on the next pass rather than silently diverging.
struct ConversationDetailView: View {
    let conversationID: UUID

    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var conversation: ConversationDTO?
    @State private var lines: [TranscriptLineDTO] = []
    @State private var summary: SummaryDTO?
    @State private var speakers: [SpeakerDTO] = []
    @State private var isLoading = true
    @State private var editingLine: TranscriptLineDTO?
    @State private var evidenceLine: TranscriptLineDTO?

    private let store = ClipperStore.shared

    var body: some View {
        List {
            if isLoading {
                LoadingPlaceholder(label: "Loading transcript")
            } else {
                summarySection
                transcriptSection
                provenanceSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(conversation?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(summary: summary)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $editingLine) { line in
            TranscriptEditSheet(line: line, speakers: speakers) { await load() }
        }
        .navigationDestination(item: $evidenceLine) { line in
            EvidenceDetailView(line: line, conversation: conversation, summary: summary)
        }
        .task { await load() }
        .onChange(of: pipeline.revision) { _, _ in Task { await load() } }
    }

    // MARK: - Sections

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if let summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.text)
                        .font(.subheadline)
                    if !summary.bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.bullets, id: \.self) { bullet in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(bullet).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        AssertionBadge(assertion: summary.assertion, confidence: summary.confidence)
                        Text(summary.generator == "foundationModels" ? "on-device model" : "sentence selection")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            } else if let conversation, conversation.isOpen {
                Label("Still in progress — summarised when it ends", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("No summary was generated for this conversation", systemImage: "text.badge.xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Summary")
        } footer: {
            if let conversation {
                Text(metaLine(conversation))
            }
        }
    }

    private var transcriptSection: some View {
        Section("Transcript") {
            if lines.isEmpty {
                Text("No transcribed lines.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    TranscriptLineRow(line: line)
                        .contentShape(Rectangle())
                        .onTapGesture { evidenceLine = line }
                        .contextMenu {
                            Button {
                                editingLine = line
                            } label: {
                                Label("Correct this line", systemImage: "pencil")
                            }
                            Button {
                                evidenceLine = line
                            } label: {
                                Label("Show evidence", systemImage: "list.bullet.indent")
                            }
                            Button {
                                UIPasteboard.general.string = line.text
                            } label: {
                                Label("Copy text", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var provenanceSection: some View {
        if let conversation {
            Section("Provenance") {
                DetailRow(label: "Started", value: conversation.startedAt.formatted(date: .abbreviated, time: .standard), systemImage: "clock")
                DetailRow(label: "Ended", value: conversation.endedAt.formatted(date: .omitted, time: .standard), systemImage: "clock.badge.checkmark")
                DetailRow(label: "Speech", value: ClipperFormat.compactDuration(conversation.speechSeconds), systemImage: "waveform")
                DetailRow(label: "Lines", value: "\(conversation.segmentCount)", systemImage: "text.alignleft")
                DetailRow(label: "Mean confidence", value: "\(Int((conversation.confidence * 100).rounded()))%", systemImage: "gauge.medium")
                if !conversation.topicNames.isEmpty {
                    DetailRow(label: "Topics", value: conversation.topicNames.joined(separator: ", "), systemImage: "tag")
                }
                if !conversation.speakerLabels.isEmpty {
                    DetailRow(label: "Voices", value: conversation.speakerLabels.joined(separator: ", "), systemImage: "person.2")
                }
            }
        }
    }

    // MARK: - Helpers

    private func metaLine(_ conversation: ConversationDTO) -> String {
        var parts = [conversation.startedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append(ClipperFormat.compactDuration(conversation.speechSeconds) + " of speech")
        if !conversation.speakerLabels.isEmpty {
            parts.append(conversation.speakerLabels.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func shareText(summary: SummaryDTO) -> String {
        var text = summary.title + "\n" + summary.text
        if !summary.bullets.isEmpty {
            text += "\n\n" + summary.bullets.map { "• " + $0 }.joined(separator: "\n")
        }
        text += "\n\nFrom Clipper · \(summary.assertion.title.lowercased())"
        return text
    }

    private func load() async {
        conversation = await store.conversation(id: conversationID)
        lines = await store.transcriptLines(conversationID: conversationID)
        if let summaryID = conversation?.summaryID {
            summary = await store.summary(id: summaryID)
        } else {
            summary = await store.summary(scope: .conversation, key: conversationID.uuidString)
        }
        speakers = await store.speakers()
        isLoading = false
    }
}

// MARK: - Line row

struct TranscriptLineRow: View {
    let line: TranscriptLineDTO

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: AudioLibrary

    private var audioURL: URL? {
        guard line.audioAvailable, let id = line.audioSegmentID else { return nil }
        return library.evidenceURL(for: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SpeakerChip(label: line.speakerLabel,
                            colorIndex: line.speakerColorIndex,
                            isUnknown: line.speakerIsUnknown,
                            confidence: line.speakerConfidence)
                Text(line.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if line.wasEdited {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Corrected by you")
                }
                if let audioURL {
                    Button {
                        player.toggle(url: audioURL, fallbackDuration: line.duration)
                    } label: {
                        Image(systemName: player.isPlaying(url: audioURL) ? "pause.circle" : "play.circle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play the audio for this line")
                } else if line.audioSegmentID != nil {
                    Image(systemName: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Audio no longer stored")
                }
            }

            Text(line.text)
                .font(.subheadline)
                .foregroundStyle(line.isLowConfidence ? .secondary : .primary)

            HStack(spacing: 8) {
                AssertionBadge(assertion: line.assertion, confidence: line.confidence, compact: true)
                if line.isLowConfidence {
                    Text("low confidence")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if line.processingState != .complete {
                    Text(line.processingState.title.lowercased())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                ScoreBar(value: line.confidence,
                         tint: line.isLowConfidence ? .orange : .green,
                         width: 30)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Correction

/// Correcting a line. The original text is kept, and reassigning a voice is stored as a
/// certainty because a person said so.
struct TranscriptEditSheet: View {
    let line: TranscriptLineDTO
    let speakers: [SpeakerDTO]
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var speakerID: UUID?

    private let store = ClipperStore.shared

    init(line: TranscriptLineDTO, speakers: [SpeakerDTO], onSave: @escaping () async -> Void) {
        self.line = line
        self.speakers = speakers
        self.onSave = onSave
        _text = State(initialValue: line.text)
        _speakerID = State(initialValue: line.speakerID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .font(.body)
                }

                Section {
                    Picker("Voice", selection: $speakerID) {
                        Text("Unknown").tag(UUID?.none)
                        ForEach(speakers) { speaker in
                            Text(speaker.label).tag(Optional(speaker.id))
                        }
                    }
                } header: {
                    Text("Attribution")
                } footer: {
                    Text("Your correction is stored as certain. The original recognised text is kept alongside it.")
                }

                if line.wasEdited {
                    Section("Already corrected") {
                        Text("This line has been edited before. The recogniser's original text is preserved in the database.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Correct line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSpeaker = speakerID
        let changedText = trimmed != line.text
        let changedSpeaker = newSpeaker != line.speakerID
        dismiss()

        Task.detached(priority: .userInitiated) {
            if changedText {
                await store.editTranscript(id: line.id, text: trimmed)
            }
            if changedSpeaker {
                await store.reassignSpeaker(segmentID: line.id, to: newSpeaker)
            }
            await onSave()
        }
    }
}
