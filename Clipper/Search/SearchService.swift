import Foundation

/// Hybrid search: an inverted index for terms, vectors for meaning, and filters on top.
///
/// ## The shape of the hot path
/// 1. Tokenise the query (microseconds).
/// 2. One indexed fetch per term against `TokenPostingRecord.token`, date-filtered in the
///    predicate. Bounded by `perTokenLimit`.
/// 3. Accumulate a TF-IDF score per document id — pure arithmetic over the postings.
/// 4. Fetch **only the top candidates** as documents (one fetch, by id set).
/// 5. Score those candidates on meaning, phrase, recency, importance and confidence.
///
/// No step reads the transcript tables, and no step scans the whole store. The only path
/// that touches documents without a term match is the semantic fallback, which is bounded
/// by count and by date — there is deliberately no code here that vector-scans everything.
///
/// ## No language model in search
/// An LLM never runs over the database to answer a search. The model is used at *write*
/// time (summaries) and optionally to phrase one answer from already-retrieved snippets in
/// `AnswerService`. Search itself is arithmetic, which is what keeps it instant after years
/// of accumulation.
actor SearchService {
    static let shared = SearchService()

    private let store: ClipperStore
    /// Documents pulled for detailed scoring. Comfortably more than a screen of results,
    /// far less than the store.
    private let candidateLimit = 160
    private let perTokenLimit = 400

    /// Rolling record of measured latencies, shown in Diagnostics.
    private var latencies: [TimeInterval] = []

    init(store: ClipperStore = .shared) {
        self.store = store
    }

    func search(_ query: SearchQuery) async -> SearchOutcome {
        let started = DispatchTime.now().uptimeNanoseconds
        let state = Log.signposter.beginInterval("search")
        defer { Log.signposter.endInterval("search", state) }

        let tokens = Tokenizer.tokens(in: query.text)
        var outcome = SearchOutcome.empty(query)
        outcome.tokens = tokens

        // Lexical pass.
        var lexical: [UUID: Double] = [:]
        var matchedTokens: [UUID: Set<String>] = [:]

        if !tokens.isEmpty {
            let postings = await store.postings(for: tokens,
                                                from: query.from,
                                                to: query.to,
                                                perTokenLimit: perTokenLimit)
            let frequencies = await store.documentFrequencies(for: tokens)
            let total = max(1, await store.documentCount())

            for hit in postings {
                let df = max(1, frequencies[hit.token] ?? 1)
                // BM25-style IDF: rare terms dominate, and a term in nearly every document
                // contributes almost nothing.
                let idf = log(1 + (Double(total) - Double(df) + 0.5) / (Double(df) + 0.5))
                lexical[hit.documentID, default: 0] += hit.weight * idf
                matchedTokens[hit.documentID, default: []].insert(hit.token)
            }
        }

        outcome.lexicalCandidates = lexical.count

        // Candidate set.
        var candidates: [IndexedDocumentSnapshot]
        if lexical.isEmpty {
            // Nothing matched a term. Either the query is only filters, or it is phrased
            // entirely differently from the stored words — which is the case semantic
            // search exists for.
            outcome.usedSemanticFallback = !tokens.isEmpty
            candidates = await store.semanticCandidates(kinds: query.kinds,
                                                        from: query.from,
                                                        to: query.to,
                                                        limit: candidateLimit * 3)
            outcome.semanticCandidates = candidates.count
        } else {
            let topIDs = lexical
                .sorted { $0.value > $1.value }
                .prefix(candidateLimit)
                .map(\.key)
            candidates = await store.documents(ids: Array(topIDs))
        }

        guard !candidates.isEmpty else {
            outcome.elapsed = Self.seconds(since: started)
            record(outcome.elapsed)
            return outcome
        }

        // Semantic pass over the candidate set only.
        var queryVector: [Float] = []
        if query.semanticEnabled, !query.text.isEmpty {
            queryVector = await Embedder.shared.vector(for: query.text)
        }

        let maximumLexical = lexical.values.max() ?? 1
        let now = Date()
        var hits: [SearchHitDTO] = []
        hits.reserveCapacity(candidates.count)

        for document in candidates {
            guard passesFilters(document, query: query) else { continue }

            let lexicalScore = maximumLexical > 0
                ? min(1, (lexical[document.id] ?? 0) / maximumLexical)
                : 0

            var semanticScore = 0.0
            if !queryVector.isEmpty, !document.embedding.isEmpty {
                // Cosine is -1...1; only positive similarity is evidence of relevance.
                semanticScore = max(0, VectorMath.cosine(queryVector, document.embedding))
            }

            let ageDays = max(0, now.timeIntervalSince(document.timestamp) / 86_400)
            let recencyScore = 1 / (1 + ageDays / 30)

            // Exact phrases are what people actually remember, so a literal match on the
            // typed phrase outranks a good bag-of-words score.
            let phraseBonus = Tokenizer.containsPhrase(query.text, in: document.text)
                || Tokenizer.containsPhrase(query.text, in: document.title) ? 0.25 : 0

            var score = 0.48 * lexicalScore
                + 0.22 * semanticScore
                + 0.12 * recencyScore
                + 0.09 * document.importance
                + 0.09 * document.confidence
                + phraseBonus

            // Contradictory and unsupported material is still findable, but it does not
            // get to lead.
            switch document.assertion {
            case .contradictory: score *= 0.85
            case .unsupported: score *= 0.7
            case .uncertain: score *= 0.92
            default: break
            }

            guard score > 0.02 else { continue }

            let matched = Array(matchedTokens[document.id] ?? [])
            hits.append(SearchHitDTO(id: document.id,
                                     kind: document.kind,
                                     refID: document.refID,
                                     conversationID: document.conversationID,
                                     title: document.title,
                                     snippet: Self.snippet(from: document.text,
                                                           query: query.text,
                                                           tokens: matched),
                                     timestamp: document.timestamp,
                                     assertion: document.assertion,
                                     confidence: document.confidence,
                                     importance: document.importance,
                                     score: score,
                                     lexicalScore: lexicalScore,
                                     semanticScore: semanticScore,
                                     recencyScore: recencyScore,
                                     matchedTokens: matched,
                                     speakerLabels: []))
        }

        hits.sort { $0.score > $1.score }
        outcome.hits = Array(hits.prefix(query.limit))
        outcome.elapsed = Self.seconds(since: started)
        record(outcome.elapsed)

        Log.search.debug("Search '\(query.text, privacy: .private)' → \(outcome.hits.count) hits in \(String(format: "%.1f", outcome.elapsed * 1000))ms")
        return outcome
    }

    /// Chronological list for "find every time I mentioned X".
    func allMentions(of query: SearchQuery) async -> [SearchHitDTO] {
        var widened = query
        widened.limit = 300
        let outcome = await search(widened)
        return outcome.hits.sorted { $0.timestamp < $1.timestamp }
    }

    /// Earliest match, for "when did I first discuss X?".
    func firstMention(of query: SearchQuery) async -> SearchHitDTO? {
        await allMentions(of: query).first
    }

    // MARK: - Filters

    private func passesFilters(_ document: IndexedDocumentSnapshot, query: SearchQuery) -> Bool {
        if !query.kinds.isEmpty, !query.kinds.contains(document.kind) { return false }
        if let from = query.from, document.timestamp < from { return false }
        if let to = query.to, document.timestamp >= to { return false }
        if !query.speakerIDs.isEmpty {
            guard !Set(document.speakerIDs).intersection(query.speakerIDs).isEmpty else { return false }
        }
        if !query.nodeIDs.isEmpty {
            guard !Set(document.nodeIDs).intersection(query.nodeIDs).isEmpty else { return false }
        }
        if !query.assertions.isEmpty, !query.assertions.contains(document.assertion) { return false }
        if document.confidence < query.minimumConfidence { return false }
        if document.importance < query.minimumImportance { return false }
        if let conversationID = query.conversationID, document.conversationID != conversationID { return false }
        return true
    }

    // MARK: - Snippets

    /// A window of text around the first match, so the result explains itself.
    static func snippet(from text: String, query: String, tokens: [String], width: Int = 180) -> String {
        guard text.count > width else { return text }

        // Prefer the literal phrase; fall back to the first matching term.
        var matchRange = text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                   options: [.caseInsensitive, .diacriticInsensitive])
        if matchRange == nil {
            for token in tokens {
                if let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                    matchRange = range
                    break
                }
            }
        }

        guard let matchRange else { return String(text.prefix(width)) + "…" }

        let padding = width / 2
        let lowerOffset = max(0, text.distance(from: text.startIndex, to: matchRange.lowerBound) - padding)
        let start = text.index(text.startIndex, offsetBy: lowerOffset)
        let end = text.index(start, offsetBy: min(width, text.distance(from: start, to: text.endIndex)))

        var snippet = String(text[start..<end])
        if lowerOffset > 0 { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    // MARK: - Measurement

    private func record(_ elapsed: TimeInterval) {
        latencies.append(elapsed)
        if latencies.count > 50 { latencies.removeFirst(latencies.count - 50) }
    }

    /// Measured search latency, for Diagnostics and for `docs/PERFORMANCE.md`.
    func latencyReport() -> (samples: Int, mean: TimeInterval, worst: TimeInterval) {
        guard !latencies.isEmpty else { return (0, 0, 0) }
        let mean = latencies.reduce(0, +) / Double(latencies.count)
        return (latencies.count, mean, latencies.max() ?? 0)
    }

    private static func seconds(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
