import SwiftUI

/// The evidence screen: one transcript line, everything above it, and everything under it.
///
/// This is the chain the spec asks for, rendered top to bottom:
///
/// ```
/// memory / summary  →  conversation  →  this line  →  timestamp  →  audio
/// ```
///
/// It is also where the app is at its most explicitly honest. Word timings come from the
/// recogniser, the audio either exists or is stated to have expired, and the memories this
/// line produced are listed so a claim can be traced in both directions.
struct EvidenceDetailView: View {
    let line: TranscriptLineDTO
    let conversation: ConversationDTO?
    let summary: SummaryDTO?

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: AudioLibrary

    @State private var citingMemories: [MemoryDTO] = []
    @State private var audioQuality: Double = 0
    @State private var isLoading = true

    private let store = ClipperStore.shared

    private var audioURL: URL? {
        guard line.audioAvailable, let id = line.audioSegmentID else { return nil }
        let candidate = library.evidenceURL(for: id)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var body: some View {
        List {
            chainSection
            audioSection
            qualitySection
            timingSection
            derivedSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Evidence")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            citingMemories = await store.memoriesCiting(sourceID: line.id)
            if let id = line.audioSegmentID {
                audioQuality = await store.segmentQuality(id: id)
            }
            isLoading = false
        }
    }

    // MARK: - Sections

    private var chainSection: some View {
        Section {
            if let summary {
                chainStep(icon: "doc.text",
                          title: summary.title,
                          subtitle: summary.text,
                          badge: AssertionBadge(assertion: summary.assertion, confidence: summary.confidence))
            }
            if let conversation {
                chainStep(icon: "bubble.left.and.bubble.right",
                          title: conversation.title,
                          subtitle: "\(conversation.segmentCount) lines · \(conversation.startedAt.formatted(date: .abbreviated, time: .shortened))",
                          badge: nil)
            }
            chainStep(icon: "quote.opening",
                      title: line.text,
                      subtitle: "\(line.speakerLabel) · \(line.startedAt.formatted(date: .abbreviated, time: .standard))",
                      badge: AssertionBadge(assertion: line.assertion, confidence: line.confidence))
        } header: {
            Text("Chain")
        } footer: {
            Text("Every derived statement in Clipper resolves to a line like this one, with a timestamp and — while it is retained — the audio.")
        }
    }

    private func chainStep(icon: String, title: String, subtitle: String, badge: AssertionBadge?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let badge { badge }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var audioSection: some View {
        Section("Audio source") {
            if let audioURL {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            player.toggle(url: audioURL, fallbackDuration: line.duration)
                        } label: {
                            Image(systemName: player.isPlaying(url: audioURL) ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .subtleGlass()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ClipperFormat.clock(line.duration))
                                .font(.subheadline.monospacedDigit())
                            Text("Retained speech clip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        ShareLink(item: audioURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }

                    if player.isLoaded(url: audioURL) {
                        Slider(value: Binding(get: { player.position },
                                              set: { player.position = $0 }),
                               in: 0...max(player.duration, 0.1),
                               onEditingChanged: { editing in if !editing { player.commitScrub() } })
                        .tint(.accentColor)
                    }
                }
                .padding(.vertical, 2)
            } else if line.audioSegmentID != nil {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio no longer stored")
                            .font(.subheadline)
                        Text("The retention policy removed it. The transcript and everything derived from it are unaffected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.slash").foregroundStyle(.orange)
                }
            } else {
                Label("No audio was retained for this line", systemImage: "waveform.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualitySection: some View {
        Section {
            DetailRow(label: "Recogniser confidence",
                      value: "\(Int((line.confidence * 100).rounded()))%",
                      systemImage: "text.bubble")
            DetailRow(label: "Audio quality",
                      value: "\(Int((audioQuality * 100).rounded()))%",
                      systemImage: "waveform.path.ecg")
            DetailRow(label: "Voice match",
                      value: line.speakerID == nil
                          ? "Not attributed"
                          : "\(Int((line.speakerConfidence * 100).rounded()))%",
                      systemImage: "person.wave.2")
            DetailRow(label: "Processing",
                      value: line.processingState.title,
                      systemImage: "gearshape")
            if line.wasEdited {
                DetailRow(label: "Corrected", value: "By you", systemImage: "pencil")
            }
        } header: {
            Text("Quality")
        } footer: {
            Text(line.isLowConfidence
                 ? "This line is marked low confidence: either the recogniser was unsure, the audio was poor, or music was bleeding into the microphone. Treat it as uncertain."
                 : "Voice matching groups similar audio into clusters. It is not speaker recognition and a name is only ever as good as the grouping.")
        }
    }

    @ViewBuilder
    private var timingSection: some View {
        if !line.wordTimings.isEmpty {
            Section {
                // A wrapped flow of word chips, each showing the recogniser's own timing
                // and per-word confidence.
                WordTimingFlow(words: line.wordTimings)
            } header: {
                Text("Word timings")
            } footer: {
                Text("Offsets are from the start of this clip, as reported by the on-device recogniser.")
            }
        }
    }

    @ViewBuilder
    private var derivedSection: some View {
        Section {
            if isLoading {
                LoadingPlaceholder(label: "Checking")
            } else if citingMemories.isEmpty {
                Text("Nothing durable was built from this line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(citingMemories) { memory in
                    NavigationLink {
                        MemoryDetailView(memoryID: memory.id)
                    } label: {
                        MemoryRow(memory: memory)
                    }
                }
            }
        } header: {
            Text("What this became")
        } footer: {
            Text("The memories that cite this line as evidence.")
        }
    }
}

/// Word chips, laid out in a wrapping flow.
private struct WordTimingFlow: View {
    let words: [WordTiming]

    var body: some View {
        // `LazyVGrid` with adaptive columns gives a wrapping flow without a custom Layout,
        // and keeps the row count bounded for long lines.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)],
                  alignment: .leading,
                  spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                VStack(spacing: 1) {
                    Text(word.text)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Text(String(format: "%.1fs", word.offset))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(tint(for: word).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 2)
    }

    /// Words the recogniser was unsure about are visibly unsure.
    private func tint(for word: WordTiming) -> Color {
        guard word.confidence > 0 else { return .secondary }
        if word.confidence < 0.4 { return .orange }
        if word.confidence < 0.7 { return .yellow }
        return .green
    }
}
