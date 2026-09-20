import SwiftUI

/// Ask a question, get an answer with its evidence — or a straight "nothing supports that".
///
/// The answer card is the one place in the app where a sentence is generated rather than
/// quoted, so it always carries its assertion label, its confidence and the name of
/// whatever produced it. Below it, the chain: memory → conversation → line → timestamp →
/// audio.
struct SearchView: View {
    @EnvironmentObject private var router: AppRouter

    @State private var text = ""
    @State private var outcome: SearchOutcome?
    @State private var answer: AnswerDTO?
    @State private var isSearching = false
    @State private var showingFilters = false
    @State private var filters = SearchFilters()
    @State private var speakers: [SpeakerDTO] = []
    @State private var searchTask: Task<Void, Never>?

    private let answers = AnswerService.shared

    var body: some View {
        NavigationStack {
            List {
                if isSearching && outcome == nil {
                    LoadingPlaceholder(label: "Searching")
                }

                if let answer, !text.isEmpty {
                    answerSection(answer)
                    if !answer.chains.isEmpty { chainSection(answer) }
                }

                if let outcome {
                    resultSection(outcome)
                    statsSection(outcome)
                } else if !isSearching {
                    suggestionSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Ask, or search what you said")
            .onSubmit(of: .search) { run(immediately: true) }
            .onChange(of: text) { _, _ in run(immediately: false) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filters", systemImage: filters.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                SearchFilterSheet(filters: $filters, speakers: speakers) {
                    run(immediately: true)
                }
            }
            .task {
                speakers = await ClipperStore.shared.speakers()
                if !router.searchText.isEmpty {
                    text = router.searchText
                    router.searchText = ""
                    run(immediately: true)
                }
            }
            .onChange(of: router.pendingSearchSubmit) { _, pending in
                guard pending else { return }
                text = router.searchText
                router.searchText = ""
                router.pendingSearchSubmit = false
                run(immediately: true)
            }
        }
    }

    // MARK: - Sections

    private func answerSection(_ answer: AnswerDTO) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if answer.insufficientEvidence {
                    Label {
                        Text(answer.answer)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(answer.answer)
                        .font(.subheadline)
                }

                HStack(spacing: 8) {
                    AssertionBadge(assertion: answer.assertion, confidence: answer.confidence)
                    Text(generatorLabel(answer.generator))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if answer.assertion == .inferred {
                    Text("Phrased by the on-device model from the excerpts below, and nothing else.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if answer.assertion == .contradictory {
                    Text("Your own statements disagree. Both are kept — see Contradictions.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Answer")
        }
    }

    private func chainSection(_ answer: AnswerDTO) -> some View {
        Section {
            ForEach(answer.chains) { chain in
                NavigationLink {
                    EvidenceDetailView(line: chain.leaf,
                                       conversation: chain.conversation,
                                       summary: chain.summary)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chain.leaf.text)
                            .font(.footnote)
                            .lineLimit(3)
                        HStack(spacing: 6) {
                            SpeakerChip(label: chain.leaf.speakerLabel,
                                        colorIndex: chain.leaf.speakerColorIndex,
                                        isUnknown: chain.leaf.speakerIsUnknown)
                            Text(chain.leaf.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            if chain.audioURL != nil {
                                Image(systemName: "waveform")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else if chain.audioExpired {
                                Image(systemName: "waveform.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Supporting evidence")
        } footer: {
            Text("Each line resolves to a timestamp and, while the audio is retained, to the recording itself.")
        }
    }

    private func resultSection(_ outcome: SearchOutcome) -> some View {
        Section {
            if outcome.hits.isEmpty {
                Text(outcome.usedSemanticFallback
                     ? "No stored words match, and nothing came close in meaning either."
                     : "No results.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(outcome.hits) { hit in
                    SearchHitRow(hit: hit)
                }
            }
        } header: {
            HStack {
                Text("Results")
                Spacer()
                if let summary = outcome.query.filterSummary(
                    speakerNames: speakerNames(for: outcome.query.speakerIDs),
                    topicNames: []
                ) {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }
        }
    }

    /// Ranking is inspectable on purpose: an opaque relevance score in a memory system is
    /// something the user has to take on faith, and this app is trying not to ask for that.
    private func statsSection(_ outcome: SearchOutcome) -> some View {
        Section {
            DetailRow(label: "Time",
                      value: String(format: "%.0f ms", outcome.elapsed * 1000),
                      systemImage: "timer")
            DetailRow(label: "Term matches",
                      value: "\(outcome.lexicalCandidates)",
                      systemImage: "text.magnifyingglass")
            if outcome.usedSemanticFallback {
                DetailRow(label: "Meaning-only candidates",
                          value: "\(outcome.semanticCandidates)",
                          systemImage: "brain")
            }
            if !outcome.tokens.isEmpty {
                DetailRow(label: "Terms searched",
                          value: outcome.tokens.joined(separator: ", "),
                          systemImage: "number")
            }
        } header: {
            Text("How this was found")
        }
    }

    private var suggestionSection: some View {
        Section {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    text = suggestion
                    run(immediately: true)
                } label: {
                    HStack {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(suggestion).font(.subheadline)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Try")
        } footer: {
            Text("Clipper understands \u{201C}yesterday\u{201D}, \u{201C}last week\u{201D} and people's names in the question itself, and shows you how it read your words.")
        }
    }

    private static let suggestions = [
        "What did I say yesterday?",
        "Find every time I mentioned this project",
        "What evidence do I have for that",
        "When did I first discuss this idea",
        "Summarise everything I said about work",
        "What changed between my earlier and later statements",
    ]

    // MARK: - Running

    private func run(immediately: Bool) {
        searchTask?.cancel()
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard raw.count >= 2 else {
            outcome = nil
            answer = nil
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            // Debounce typing, but never delay a deliberate submit.
            if !immediately {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }

            var query = await answers.buildQuery(from: raw, limit: 40)
            filters.apply(to: &query)

            let result = await answers.runSearch(query: query)
            if Task.isCancelled { return }

            // A question gets an answer; a bare keyword just gets results.
            let intent = QueryParser.intent(of: raw)
            var composed: AnswerDTO?
            if intent != .lookup {
                composed = await answers.answer(raw)
            }
            if Task.isCancelled { return }

            outcome = result
            answer = composed
            isSearching = false
        }
    }

    private func generatorLabel(_ generator: String) -> String {
        switch generator {
        case "foundationModels": return "phrased by the on-device model"
        case "retrieval": return "quoted from your transcripts"
        default: return "no supporting material"
        }
    }

    private func speakerNames(for ids: [UUID]) -> [String] {
        ids.compactMap { id in speakers.first { $0.id == id }?.displayName }
    }
}

// MARK: - Hit row

struct SearchHitRow: View {
    let hit: SearchHitDTO

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(hit.title.isEmpty ? hit.kind.label : hit.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(hit.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(hit.snippet)
                    .font(.footnote)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    AssertionBadge(assertion: hit.assertion, confidence: hit.confidence, compact: true)
                    if hit.semanticScore > hit.lexicalScore, hit.semanticScore > 0.2 {
                        Text("matched on meaning")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    } else if !hit.matchedTokens.isEmpty {
                        Text(hit.matchedTokens.prefix(3).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ScoreBar(value: min(1, hit.score), width: 28)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch hit.kind {
        case .transcriptSegment, .conversation:
            ConversationDetailView(conversationID: hit.conversationID ?? hit.refID)
        case .memory:
            MemoryDetailView(memoryID: hit.refID)
        case .summary:
            SummaryDetailView(summaryID: hit.refID)
        case .speaker:
            SpeakerDetailView(speakerID: hit.refID)
        case .node:
            BrainMapView(focusNodeID: hit.refID)
        }
    }

    private var icon: String {
        switch hit.kind {
        case .transcriptSegment: return "quote.opening"
        case .conversation: return "bubble.left.and.bubble.right"
        case .summary: return "doc.text"
        case .memory: return "brain"
        case .speaker: return "person"
        case .node: return "tag"
        }
    }
}

// MARK: - Summary detail

struct SummaryDetailView: View {
    let summaryID: UUID

    @State private var summary: SummaryDTO?
    @State private var sources: [TranscriptLineDTO] = []
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            if isLoading {
                LoadingPlaceholder()
            } else if let summary {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.text).font(.subheadline)
                        ForEach(summary.bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(bullet).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        AssertionBadge(assertion: summary.assertion, confidence: summary.confidence)
                    }
                } header: {
                    Text(summary.scope.title)
                } footer: {
                    Text("\(summary.periodStart.formatted(date: .abbreviated, time: .omitted)) · revision \(summary.revision) · \(summary.generator == "foundationModels" ? "on-device model" : "sentence selection")")
                }

                Section("Built from") {
                    if sources.isEmpty {
                        Text("Built from lower-level summaries rather than directly from transcript lines.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sources) { line in
                            NavigationLink {
                                EvidenceDetailView(line: line, conversation: nil, summary: summary)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(line.text).font(.footnote).lineLimit(2)
                                    Text(line.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Summary not found", systemImage: "doc.questionmark")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(summary?.title ?? "Summary")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            summary = await store.summary(id: summaryID)
            if let ids = summary?.sourceIDs {
                sources = await store.transcriptLines(ids: ids)
            }
            isLoading = false
        }
    }
}

// MARK: - Filters

struct SearchFilters {
    var kinds: Set<DocumentKind> = []
    var speakerIDs: Set<UUID> = []
    var assertions: Set<AssertionKind> = []
    var minimumConfidence: Double = 0
    var window: Window = .any

    enum Window: String, CaseIterable, Identifiable {
        case any, today, week, month, year
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "Any time"
            case .today: return "Today"
            case .week: return "This week"
            case .month: return "This month"
            case .year: return "This year"
            }
        }

        var bounds: (Date, Date)? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .any: return nil
            case .today:
                let start = calendar.startOfDay(for: now)
                return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
            case .week:
                guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
                return (interval.start, interval.end)
            case .month:
                guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
                return (interval.start, interval.end)
            case .year:
                guard let interval = calendar.dateInterval(of: .year, for: now) else { return nil }
                return (interval.start, interval.end)
            }
        }
    }

    var isActive: Bool {
        !kinds.isEmpty || !speakerIDs.isEmpty || !assertions.isEmpty
            || minimumConfidence > 0 || window != .any
    }

    /// Explicit filters win over anything the parser inferred from the wording.
    func apply(to query: inout SearchQuery) {
        if !kinds.isEmpty { query.kinds = Array(kinds) }
        if !speakerIDs.isEmpty { query.speakerIDs = Array(speakerIDs) }
        if !assertions.isEmpty { query.assertions = Array(assertions) }
        if minimumConfidence > 0 { query.minimumConfidence = minimumConfidence }
        if let bounds = window.bounds {
            query.from = bounds.0
            query.to = bounds.1
        }
    }
}

struct SearchFilterSheet: View {
    @Binding var filters: SearchFilters
    let speakers: [SpeakerDTO]
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    Picker("Period", selection: $filters.window) {
                        ForEach(SearchFilters.Window.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("What") {
                    ForEach(DocumentKind.allCases, id: \.self) { kind in
                        Toggle(kind.label.capitalized, isOn: binding(for: kind))
                    }
                }

                if !speakers.isEmpty {
                    Section("Who") {
                        ForEach(speakers) { speaker in
                            Toggle(speaker.label, isOn: binding(for: speaker.id))
                        }
                    }
                }

                Section {
                    ForEach(AssertionKind.allCases, id: \.self) { assertion in
                        Toggle(assertion.title, isOn: binding(for: assertion))
                    }
                } header: {
                    Text("How strongly claimed")
                } footer: {
                    Text("Filter to only what was said out loud, or only what Clipper inferred.")
                }

                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Minimum confidence")
                            Spacer()
                            Text("\(Int((filters.minimumConfidence * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $filters.minimumConfidence, in: 0...0.9, step: 0.05)
                    }
                }

                Section {
                    Button("Clear all filters") {
                        filters = SearchFilters()
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }

    private func binding(for kind: DocumentKind) -> Binding<Bool> {
        Binding(get: { filters.kinds.contains(kind) },
                set: { on in
                    if on { filters.kinds.insert(kind) } else { filters.kinds.remove(kind) }
                })
    }

    private func binding(for speakerID: UUID) -> Binding<Bool> {
        Binding(get: { filters.speakerIDs.contains(speakerID) },
                set: { on in
                    if on { filters.speakerIDs.insert(speakerID) } else { filters.speakerIDs.remove(speakerID) }
                })
    }

    private func binding(for assertion: AssertionKind) -> Binding<Bool> {
        Binding(get: { filters.assertions.contains(assertion) },
                set: { on in
                    if on { filters.assertions.insert(assertion) } else { filters.assertions.remove(assertion) }
                })
    }
}
