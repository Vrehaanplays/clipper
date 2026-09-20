import Foundation

/// A search, after parsing. Every filter the spec asks for is a field here, so the ranking
/// function never has to guess what the user meant.
struct SearchQuery: Hashable, Sendable {
    var text: String
    var kinds: [DocumentKind] = []
    var speakerIDs: [UUID] = []
    var nodeIDs: [UUID] = []
    var from: Date?
    var to: Date?
    var assertions: [AssertionKind] = []
    var minimumConfidence: Double = 0
    var minimumImportance: Double = 0
    var conversationID: UUID?
    var limit: Int = 40
    var semanticEnabled: Bool = true

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && speakerIDs.isEmpty && nodeIDs.isEmpty && from == nil && kinds.isEmpty
    }

    /// A one-line description of what is actually being filtered, shown under the search
    /// field so the user can see how their words were interpreted.
    func filterSummary(speakerNames: [String], topicNames: [String]) -> String? {
        var parts: [String] = []
        if let from, let to {
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append(formatter.string(from: from, to: to))
        } else if let from {
            parts.append("since " + from.formatted(date: .abbreviated, time: .omitted))
        }
        if !speakerNames.isEmpty { parts.append("said by " + speakerNames.joined(separator: ", ")) }
        if !topicNames.isEmpty { parts.append("about " + topicNames.joined(separator: ", ")) }
        if !kinds.isEmpty {
            parts.append(kinds.map { $0.label }.joined(separator: ", "))
        }
        if minimumConfidence > 0 { parts.append("confidence ≥ \(Int(minimumConfidence * 100))%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension DocumentKind {
    var label: String {
        switch self {
        case .transcriptSegment: return "transcript"
        case .conversation: return "conversations"
        case .summary: return "summaries"
        case .memory: return "memories"
        case .speaker: return "people"
        case .node: return "topics"
        }
    }
}

/// What a search run produced, including the numbers Diagnostics shows so ranking is
/// inspectable rather than magic.
struct SearchOutcome: Sendable {
    var hits: [SearchHitDTO]
    var elapsed: TimeInterval
    var lexicalCandidates: Int
    var semanticCandidates: Int
    /// True when no term matched and the search fell back to vectors only.
    var usedSemanticFallback: Bool
    var tokens: [String]
    var query: SearchQuery

    static func empty(_ query: SearchQuery) -> SearchOutcome {
        SearchOutcome(hits: [], elapsed: 0, lexicalCandidates: 0, semanticCandidates: 0,
                      usedSemanticFallback: false, tokens: [], query: query)
    }
}

/// Turns what the user typed into filters.
///
/// Deliberately a small set of rules rather than a language model: it runs on every
/// keystroke, it must be instant, and the user can see exactly what it decided in the
/// filter summary under the field. Anything it does not recognise stays in `text` and is
/// searched normally, so a mis-parse degrades to a plain search rather than to no results.
struct QueryParser {
    /// Relative date phrases, longest first so "last week" wins over "week".
    private static let datePhrases: [(phrase: String, resolve: (Date, Calendar) -> (Date, Date)?)] = [
        ("yesterday", { now, calendar in
            guard let day = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            let start = calendar.startOfDay(for: day)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        }),
        ("today", { now, calendar in
            let start = calendar.startOfDay(for: now)
            return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? now)
        }),
        ("last week", { now, calendar in
            guard let weekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: weekAgo)
            else { return nil }
            return (interval.start, interval.end)
        }),
        ("this week", { now, calendar in
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return (interval.start, interval.end)
        }),
        ("last month", { now, calendar in
            guard let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                  let interval = calendar.dateInterval(of: .month, for: monthAgo)
            else { return nil }
            return (interval.start, interval.end)
        }),
        ("this month", { now, calendar in
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
            return (interval.start, interval.end)
        }),
    ]

    /// Phrases that narrow the result type.
    private static let kindPhrases: [(String, DocumentKind)] = [
        ("summar", .summary),
        ("decision", .memory),
        ("remind", .memory),
        ("memor", .memory),
        ("conversation", .conversation),
        ("transcript", .transcriptSegment),
    ]

    /// Known speaker names, supplied by the caller so the parser stays pure.
    var knownSpeakers: [(id: UUID, name: String)] = []
    var knownNodes: [(id: UUID, name: String)] = []
    var calendar: Calendar = .current

    func parse(_ raw: String, now: Date = Date(), limit: Int = 40) -> SearchQuery {
        var residual = raw
        var query = SearchQuery(text: raw, limit: limit)

        // Dates.
        for entry in Self.datePhrases {
            guard let range = residual.range(of: entry.phrase, options: [.caseInsensitive]) else { continue }
            if let bounds = entry.resolve(now, calendar) {
                query.from = bounds.0
                query.to = bounds.1
                residual.removeSubrange(range)
            }
            break
        }

        // Speakers: "what did Vrehaan say about…", "Vrehaan's view".
        for speaker in knownSpeakers {
            guard speaker.name.count >= 2,
                  let range = residual.range(of: speaker.name, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            query.speakerIDs.append(speaker.id)
            residual.removeSubrange(range)
        }

        // Topics and projects.
        for node in knownNodes where node.name.count >= 3 {
            guard let range = residual.range(of: node.name, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            query.nodeIDs.append(node.id)
            // The node name stays in the text: it is a strong lexical signal too.
            _ = range
        }

        // Result kinds.
        let lowered = residual.lowercased()
        for (fragment, kind) in Self.kindPhrases where lowered.contains(fragment) {
            if !query.kinds.contains(kind) { query.kinds.append(kind) }
        }

        // Strip the interrogative scaffolding so "what did I say about the budget" searches
        // for "budget" rather than for "what did I say".
        let scaffolding = ["what did i say about", "what did i say", "what do i know about",
                           "find every time i mentioned", "find every time i mentioned",
                           "show all conversations related to", "show me", "find", "search for",
                           "tell me about", "when did i first discuss", "what evidence do i have for",
                           "summarize everything i said about", "summarise everything i said about",
                           "what changed between my earlier and later statements about",
                           "what changed about", "say about", "did i"]
        var cleaned = residual
        for phrase in scaffolding {
            if let range = cleaned.range(of: phrase, options: [.caseInsensitive]) {
                cleaned.removeSubrange(range)
            }
        }

        query.text = cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.,'\"").union(.whitespacesAndNewlines))
        // Everything was scaffolding: keep the original so the search is not empty.
        if query.text.isEmpty && query.speakerIDs.isEmpty && query.nodeIDs.isEmpty {
            query.text = raw
        }
        return query
    }

    /// Which question shape this is, used by the answering layer to pick a strategy.
    static func intent(of raw: String) -> QuestionIntent {
        let lowered = raw.lowercased()
        if lowered.contains("what changed") || lowered.contains("did i change") { return .change }
        if lowered.contains("evidence") { return .evidence }
        if lowered.contains("when did i first") || lowered.contains("first discuss") { return .firstMention }
        if lowered.contains("summar") { return .summary }
        if lowered.contains("every time") || lowered.contains("all conversations") { return .enumerate }
        if lowered.hasSuffix("?") || ContentExtractor.isQuestion(lowered) { return .question }
        return .lookup
    }
}

enum QuestionIntent: String, Sendable {
    /// Plain keyword lookup.
    case lookup
    /// A question expecting a sentence back.
    case question
    /// "Summarise everything I said about X."
    case summary
    /// "Find every time I mentioned X."
    case enumerate
    /// "When did I first discuss X?"
    case firstMention
    /// "What evidence do I have for X?"
    case evidence
    /// "What changed between my earlier and later statements?"
    case change
}
