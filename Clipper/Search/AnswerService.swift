import Foundation

/// Answers questions with a chain back to the audio.
///
/// Every answer carries an `AssertionKind`, and the rules for it are fixed rather than
/// judged case by case:
///
/// | Where the answer came from | Label |
/// |---|---|
/// | Quoted from a transcript segment marked `stated` | `.stated` |
/// | Drawn from a generated summary | `.summarised` |
/// | Phrased by the language model from retrieved excerpts | `.inferred` |
/// | Best evidence was low-confidence or an unknown speaker | `.uncertain` |
/// | Supporting memories disagree | `.contradictory` |
/// | Nothing matched | `.unsupported`, with `insufficientEvidence` set |
///
/// The last row is the one that matters most: when there is nothing to go on, the answer
/// says so instead of producing a plausible sentence.
actor AnswerService {
    static let shared = AnswerService()

    private let store: ClipperStore
    private let search: SearchService
    private let library: AudioLibrary
    private let settings: AppSettings
    private let answerer = FoundationModelAnswerer()

    /// Cached so the parser does not refetch the vocabulary on every keystroke.
    private var speakerVocabulary: [(id: UUID, name: String)] = []
    private var nodeVocabulary: [(id: UUID, name: String)] = []
    private var vocabularyLoadedAt: Date?

    init(store: ClipperStore = .shared,
         search: SearchService = .shared,
         library: AudioLibrary = .shared,
         settings: AppSettings = .shared) {
        self.store = store
        self.search = search
        self.library = library
        self.settings = settings
    }

    // MARK: - Query building

    /// Parse raw user text into a query, using the current speaker and topic vocabulary.
    func buildQuery(from raw: String, limit: Int = 40) async -> SearchQuery {
        await refreshVocabularyIfNeeded()
        var parser = QueryParser()
        parser.knownSpeakers = speakerVocabulary
        parser.knownNodes = nodeVocabulary
        return parser.parse(raw, limit: limit)
    }

    func runSearch(_ raw: String, limit: Int = 40) async -> SearchOutcome {
        let query = await buildQuery(from: raw, limit: limit)
        var outcome = await search.search(query)
        outcome.hits = await decorate(outcome.hits)
        return outcome
    }

    func runSearch(query: SearchQuery) async -> SearchOutcome {
        var outcome = await search.search(query)
        outcome.hits = await decorate(outcome.hits)
        return outcome
    }

    private func refreshVocabularyIfNeeded() async {
        if let loadedAt = vocabularyLoadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        speakerVocabulary = await store.speakers()
            .compactMap { speaker in
                guard let name = speaker.displayName, name.count >= 2 else { return nil }
                return (speaker.id, name)
            }
        nodeVocabulary = await store.nodes(limit: 120)
            .filter { $0.name.count >= 3 }
            .map { ($0.id, $0.name) }
        vocabularyLoadedAt = Date()
    }

    /// Fill in speaker labels, which search itself does not load.
    private func decorate(_ hits: [SearchHitDTO]) async -> [SearchHitDTO] {
        guard !hits.isEmpty else { return hits }
        var result: [SearchHitDTO] = []
        result.reserveCapacity(hits.count)
        for hit in hits {
            guard hit.kind == .transcriptSegment,
                  let line = await store.transcriptLine(id: hit.refID) else {
                result.append(hit)
                continue
            }
            result.append(SearchHitDTO(id: hit.id,
                                       kind: hit.kind,
                                       refID: hit.refID,
                                       conversationID: hit.conversationID,
                                       title: line.speakerLabel,
                                       snippet: hit.snippet,
                                       timestamp: hit.timestamp,
                                       assertion: hit.assertion,
                                       confidence: hit.confidence,
                                       importance: hit.importance,
                                       score: hit.score,
                                       lexicalScore: hit.lexicalScore,
                                       semanticScore: hit.semanticScore,
                                       recencyScore: hit.recencyScore,
                                       matchedTokens: hit.matchedTokens,
                                       speakerLabels: [line.speakerLabel]))
        }
        return result
    }

    // MARK: - Answering

    func answer(_ raw: String) async -> AnswerDTO {
        let intent = QueryParser.intent(of: raw)
        let query = await buildQuery(from: raw, limit: intent == .enumerate ? 200 : 40)
        var outcome = await search.search(query)
        outcome.hits = await decorate(outcome.hits)

        guard !outcome.hits.isEmpty else {
            return AnswerDTO(question: raw,
                             answer: "Nothing in Clipper's memory answers that. Either it was not said while Clipper was listening, or it was not recognised.",
                             assertion: .unsupported,
                             confidence: 0,
                             chains: [],
                             hits: [],
                             insufficientEvidence: true,
                             generator: "none")
        }

        let chains = await buildChains(for: Array(outcome.hits.prefix(6)))

        switch intent {
        case .firstMention:
            return firstMentionAnswer(raw: raw, outcome: outcome, chains: chains)
        case .enumerate:
            return enumerateAnswer(raw: raw, outcome: outcome, chains: chains)
        case .change:
            return await changeAnswer(raw: raw, outcome: outcome, chains: chains)
        case .evidence:
            return evidenceAnswer(raw: raw, outcome: outcome, chains: chains)
        case .summary, .question, .lookup:
            return await composedAnswer(raw: raw, outcome: outcome, chains: chains)
        }
    }

    // MARK: - Answer shapes

    private func firstMentionAnswer(raw: String,
                                    outcome: SearchOutcome,
                                    chains: [EvidenceChainDTO]) -> AnswerDTO {
        let earliest = outcome.hits.min { $0.timestamp < $1.timestamp }
        guard let earliest else {
            return AnswerDTO(question: raw, answer: "No dated mention was found.",
                             assertion: .unsupported, confidence: 0, chains: chains,
                             hits: outcome.hits, insufficientEvidence: true, generator: "none")
        }
        let when = earliest.timestamp.formatted(date: .complete, time: .shortened)
        return AnswerDTO(question: raw,
                         answer: "The earliest mention Clipper has is \(when): \u{201C}\(earliest.snippet)\u{201D}",
                         assertion: earliest.assertion == .stated ? .stated : earliest.assertion,
                         confidence: earliest.confidence,
                         chains: chains,
                         // Chronological, not by score: the question is about when, so the
                         // list under the answer reads from the earliest mention onwards.
                         hits: outcome.hits.sorted { $0.timestamp < $1.timestamp },
                         insufficientEvidence: false,
                         generator: "retrieval")
    }

    private func enumerateAnswer(raw: String,
                                 outcome: SearchOutcome,
                                 chains: [EvidenceChainDTO]) -> AnswerDTO {
        let sorted = outcome.hits.sorted { $0.timestamp < $1.timestamp }
        let count = sorted.count
        guard let first = sorted.first, let last = sorted.last else {
            return AnswerDTO(question: raw, answer: "No mentions found.", assertion: .unsupported,
                             confidence: 0, chains: chains, hits: outcome.hits,
                             insufficientEvidence: true, generator: "none")
        }
        let span = first.timestamp.formatted(date: .abbreviated, time: .omitted)
            + " to " + last.timestamp.formatted(date: .abbreviated, time: .omitted)
        let answer = count == 1
            ? "One mention, on \(span.components(separatedBy: " to ").first ?? span)."
            : "\(count) mentions, from \(span). They are listed below, oldest first."
        return AnswerDTO(question: raw,
                         answer: answer,
                         assertion: .stated,
                         confidence: sorted.map(\.confidence).reduce(0, +) / Double(count),
                         chains: chains,
                         hits: sorted,
                         insufficientEvidence: false,
                         generator: "retrieval")
    }

    /// "What changed between my earlier and later statements?" — answered from the memory
    /// revision chain, which exists precisely because nothing is ever overwritten.
    private func changeAnswer(raw: String,
                              outcome: SearchOutcome,
                              chains: [EvidenceChainDTO]) async -> AnswerDTO {
        for hit in outcome.hits where hit.kind == .memory {
            let revisions = await store.revisionChain(for: hit.refID)
            guard revisions.count >= 2,
                  let earliest = revisions.first,
                  let latest = revisions.last else { continue }

            let answer = "Earlier (\(earliest.firstSeenAt.formatted(date: .abbreviated, time: .omitted))): \u{201C}\(earliest.title)\u{201D}. "
                + "Later (\(latest.lastSeenAt.formatted(date: .abbreviated, time: .omitted))): \u{201C}\(latest.title)\u{201D}. "
                + "Clipper kept both; the later statement supersedes the earlier one."
            return AnswerDTO(question: raw,
                             answer: answer,
                             assertion: .contradictory,
                             confidence: min(earliest.confidence, latest.confidence),
                             chains: chains,
                             hits: outcome.hits,
                             insufficientEvidence: false,
                             generator: "retrieval")
        }

        let open = await store.contradictions(limit: 6)
        if let conflict = open.first {
            return AnswerDTO(question: raw,
                             answer: conflict.explanation + " Clipper has not resolved this; both statements are kept.",
                             assertion: .contradictory,
                             confidence: conflict.confidence,
                             chains: chains,
                             hits: outcome.hits,
                             insufficientEvidence: false,
                             generator: "retrieval")
        }

        return AnswerDTO(question: raw,
                         answer: "Clipper has no record of a statement on this being revised. Only one version is stored.",
                         assertion: .stated,
                         confidence: outcome.hits.first?.confidence ?? 0,
                         chains: chains,
                         hits: outcome.hits,
                         insufficientEvidence: false,
                         generator: "retrieval")
    }

    private func evidenceAnswer(raw: String,
                                outcome: SearchOutcome,
                                chains: [EvidenceChainDTO]) -> AnswerDTO {
        let withAudio = chains.filter { $0.audioURL != nil }.count
        let expired = chains.filter(\.audioExpired).count

        var answer = chains.isEmpty
            ? "Clipper found matching text but could not trace it back to a transcript segment."
            : "\(chains.count) supporting transcript segment\(chains.count == 1 ? "" : "s")."
        if withAudio > 0 { answer += " \(withAudio) still \(withAudio == 1 ? "has" : "have") the original audio." }
        if expired > 0 { answer += " \(expired) had their audio removed by the retention policy." }

        return AnswerDTO(question: raw,
                         answer: answer,
                         assertion: chains.isEmpty ? .unsupported : .stated,
                         confidence: chains.isEmpty ? 0 : (outcome.hits.first?.confidence ?? 0.5),
                         chains: chains,
                         hits: outcome.hits,
                         insufficientEvidence: chains.isEmpty,
                         generator: "retrieval")
    }

    /// The general case. The language model phrases it when available; otherwise the best
    /// supporting lines are quoted directly, which is never wrong, only plainer.
    private func composedAnswer(raw: String,
                                outcome: SearchOutcome,
                                chains: [EvidenceChainDTO]) async -> AnswerDTO {
        let top = Array(outcome.hits.prefix(6))
        let excerpts = top.map { hit -> String in
            let when = hit.timestamp.formatted(date: .abbreviated, time: .shortened)
            let who = hit.speakerLabels.first ?? hit.title
            return "[\(when), \(who)] \(hit.snippet)"
        }

        let contradictory = top.contains { $0.assertion == .contradictory }
        let uncertain = top.allSatisfy { $0.assertion == .uncertain || $0.confidence < 0.45 }
        let meanConfidence = top.map(\.confidence).reduce(0, +) / Double(max(1, top.count))

        if settings.config.preferOnDeviceModel, await answerer.isAvailable() {
            if let grounded = await answerer.answer(question: raw, excerpts: excerpts) {
                // Only the excerpts the model said it used are offered as the chain.
                let citedChains = grounded.citedExcerpts.compactMap { number -> EvidenceChainDTO? in
                    let index = number - 1
                    return chains.indices.contains(index) ? chains[index] : nil
                }
                let assertion: AssertionKind
                if contradictory { assertion = .contradictory }
                else if uncertain { assertion = .uncertain }
                else { assertion = .inferred }

                return AnswerDTO(question: raw,
                                 answer: grounded.text,
                                 assertion: assertion,
                                 confidence: min(meanConfidence, 0.85),
                                 chains: citedChains.isEmpty ? chains : citedChains,
                                 hits: outcome.hits,
                                 insufficientEvidence: false,
                                 generator: "foundationModels")
            }
        }

        // Extractive: quote, do not compose. Cannot be wrong about what was said.
        let quoted = top.prefix(3).map { hit -> String in
            let who = hit.speakerLabels.first ?? hit.title
            let when = hit.timestamp.formatted(date: .abbreviated, time: .shortened)
            return "\(who), \(when): \u{201C}\(hit.snippet)\u{201D}"
        }
        let assertion: AssertionKind
        if contradictory { assertion = .contradictory }
        else if uncertain { assertion = .uncertain }
        else if top.first?.kind == .summary { assertion = .summarised }
        else { assertion = .stated }

        return AnswerDTO(question: raw,
                         answer: quoted.joined(separator: "\n\n"),
                         assertion: assertion,
                         confidence: meanConfidence,
                         chains: chains,
                         hits: outcome.hits,
                         insufficientEvidence: false,
                         generator: "retrieval")
    }

    // MARK: - Evidence chains

    /// answer → memory → conversation → transcript segment → timestamp → audio source.
    func buildChains(for hits: [SearchHitDTO]) async -> [EvidenceChainDTO] {
        var chains: [EvidenceChainDTO] = []
        var seenLeaves = Set<UUID>()

        for hit in hits {
            guard let chain = await buildChain(for: hit), !seenLeaves.contains(chain.leaf.id) else { continue }
            seenLeaves.insert(chain.leaf.id)
            chains.append(chain)
        }
        return chains
    }

    private func buildChain(for hit: SearchHitDTO) async -> EvidenceChainDTO? {
        var memory: MemoryDTO?
        var summary: SummaryDTO?
        var leafID: UUID?

        switch hit.kind {
        case .transcriptSegment:
            leafID = hit.refID
        case .memory:
            memory = await store.memory(id: hit.refID)
            leafID = await resolveLeaf(from: memory?.sourceIDs ?? [], sourceKind: memory?.sourceKind)
        case .summary:
            summary = await store.summary(id: hit.refID)
            leafID = await resolveLeaf(from: summary?.sourceIDs ?? [], sourceKind: summary?.sourceKind)
        case .conversation:
            let lines = await store.transcriptLines(conversationID: hit.refID, limit: 1)
            leafID = lines.first?.id
        case .speaker, .node:
            return nil
        }

        guard let leafID, let leaf = await store.transcriptLine(id: leafID) else { return nil }

        var conversationDTO: ConversationDTO?
        if let conversationID = leaf.conversationID {
            conversationDTO = await store.conversation(id: conversationID)
        }

        var audioURL: URL?
        var expired = false
        if let segmentID = leaf.audioSegmentID {
            if leaf.audioAvailable {
                let candidate = library.evidenceURL(for: segmentID)
                audioURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
                expired = audioURL == nil
            } else {
                expired = true
            }
        }

        return EvidenceChainDTO(memory: memory,
                                summary: summary,
                                conversation: conversationDTO,
                                leaf: leaf,
                                audioURL: audioURL,
                                audioExpired: expired)
    }

    /// Walk a provenance list down to a transcript segment, one hop at a time.
    ///
    /// A memory can cite a summary, and that summary cites transcript segments; the chain
    /// has to resolve through it rather than stopping at the first id it does not recognise.
    private func resolveLeaf(from sourceIDs: [UUID], sourceKind: SourceKind?) async -> UUID? {
        guard !sourceIDs.isEmpty else { return nil }

        switch sourceKind {
        case .transcriptSegment, .none:
            for id in sourceIDs {
                if await store.transcriptLine(id: id) != nil { return id }
            }
            return nil
        case .summary:
            for id in sourceIDs {
                guard let summary = await store.summary(id: id) else { continue }
                if let leaf = await resolveLeaf(from: summary.sourceIDs, sourceKind: summary.sourceKind) {
                    return leaf
                }
            }
            return nil
        case .conversation:
            for id in sourceIDs {
                let lines = await store.transcriptLines(conversationID: id, limit: 1)
                if let first = lines.first { return first.id }
            }
            return nil
        case .memory:
            for id in sourceIDs {
                guard let memory = await store.memory(id: id) else { continue }
                if let leaf = await resolveLeaf(from: memory.sourceIDs, sourceKind: memory.sourceKind) {
                    return leaf
                }
            }
            return nil
        case .audioSegment, .manual:
            return nil
        }
    }
}
