import Foundation

/// Turns a closed conversation's extractions into curated memories.
///
/// ## The dedupe key is the whole design
/// Two different key strategies, chosen per kind:
///
/// - **Claim-keyed** (facts, ideas, events, questions): the key includes the claim's content
///   words, so two different statements are two memories and the same statement twice is
///   one, reinforced.
/// - **Subject-keyed** (decisions, preferences, goals): the key is the *subject only*, so a
///   later, different statement about the same subject **collides** with the earlier one —
///   which is exactly what makes `ClipperStore.upsertMemory` supersede it and record a
///   contradiction. "We'll use Postgres" followed next week by "we're moving to SQLite"
///   becomes a revision chain with both statements readable, not two unrelated facts.
///
/// That is how "what changed between my earlier and later statements?" is answerable
/// without ever overwriting history.
struct MemoryBuilder {
    /// Which kinds supersede on change rather than accumulating.
    static let subjectKeyedKinds: Set<MemoryKind> = [.decision, .preference, .goal, .project]

    /// Base importance per kind. A reminder matters more than a passing claim.
    static func baseImportance(for kind: MemoryKind) -> Double {
        switch kind {
        case .reminder, .task: return 0.7
        case .decision, .goal: return 0.65
        case .preference, .relationship: return 0.55
        case .event: return 0.5
        case .idea, .question, .unresolved: return 0.45
        case .fact, .claim: return 0.35
        default: return 0.3
        }
    }

    /// Claims are only promoted to durable facts when there is more than one sighting or
    /// the cue was strong. Otherwise a whole day of small talk becomes "memories".
    static let claimPromotionThreshold = 0.55

    func build(extractions: [ExtractionSnapshot],
               conversation: ConversationDTO,
               keywords: [String],
               nodeIDs: [UUID],
               summary: SummaryDraft?,
               summaryID: UUID?) -> [MemoryCandidate] {
        var grouped: [String: [ExtractionSnapshot]] = [:]

        for extraction in extractions {
            guard extraction.kind != .conversation else { continue }
            let key = Self.key(for: extraction, conversationKeywords: keywords)
            guard !key.isEmpty else { continue }
            grouped[key, default: []].append(extraction)
        }

        var candidates: [MemoryCandidate] = []
        candidates.reserveCapacity(grouped.count + 1)

        for (key, group) in grouped {
            guard let best = group.max(by: { $0.confidence < $1.confidence }) else { continue }

            // A lone weak claim is not a memory.
            if best.kind == .claim || best.kind == .fact {
                let strongEnough = best.confidence >= Self.claimPromotionThreshold || group.count > 1
                guard strongEnough else { continue }
            }

            let kind: MemoryKind = (best.kind == .claim) ? .fact : best.kind
            let title = Self.title(from: best.text)
            let detail = Self.detail(from: group)
            let sourceIDs = Array(Set(group.map(\.transcriptSegmentID)))

            // Repetition within one conversation is weak corroboration: the same sentence
            // twice is often the recogniser, not the speaker.
            let repetitionBoost = min(0.12, Double(group.count - 1) * 0.04)
            let confidence = min(0.92, best.confidence + repetitionBoost)

            let importance = min(1, Self.baseImportance(for: kind)
                                 * (0.6 + 0.4 * conversation.importance)
                                 + repetitionBoost)

            // Anything the extractor was unsure about stays unsure here. Aggregation adds
            // evidence, not certainty.
            let assertion: AssertionKind = confidence >= 0.6 ? best.assertion : .uncertain

            candidates.append(MemoryCandidate(
                kind: kind,
                title: title,
                detail: detail,
                confidence: confidence,
                assertion: assertion,
                importance: importance,
                occurredAt: best.occurredAt,
                sourceKind: .transcriptSegment,
                sourceIDs: sourceIDs,
                nodeIDs: nodeIDs,
                subjectSpeakerID: best.speakerID,
                dedupeKey: key,
                occurrences: group.count,
                supersedeOnChange: Self.subjectKeyedKinds.contains(kind)
            ))
        }

        // One memory for the conversation itself, so the timeline and the brain map have
        // something to point at even when nothing else was extracted.
        if let summary, let summaryID {
            candidates.append(MemoryCandidate(
                kind: .conversation,
                title: summary.title,
                detail: summary.text,
                confidence: summary.confidence,
                assertion: .summarised,
                importance: max(0.25, conversation.importance),
                occurredAt: conversation.startedAt,
                sourceKind: .summary,
                sourceIDs: [summaryID],
                nodeIDs: nodeIDs,
                dedupeKey: "conversation|\(conversation.id.uuidString)",
                supersedeOnChange: false
            ))
        }

        return candidates.sorted { $0.importance > $1.importance }
    }

    // MARK: - Keys

    static func key(for extraction: ExtractionSnapshot, conversationKeywords: [String]) -> String {
        let kind = extraction.kind == .claim ? MemoryKind.fact : extraction.kind

        guard subjectKeyedKinds.contains(kind) else {
            return Tokenizer.dedupeKey(kind: kind,
                                       subject: extraction.subject,
                                       claim: extraction.text)
        }

        // Subject-keyed: the subject is the explicit one if the extractor found it,
        // otherwise the strongest content words this sentence shares with the
        // conversation's topics. That shared-topic fallback is what lets two statements
        // about the same decision collide even when phrased completely differently.
        if let subject = extraction.subject, !subject.isEmpty {
            return "\(kind.rawValue)|subject|\(Tokenizer.normalizeName(subject))"
        }

        // The *strongest* shared topic word, not a set of them: the conversation's
        // keyword list differs from one conversation to the next, so a key built from
        // several words would not match across conversations — and matching across
        // conversations is exactly what makes a decision reversed an hour later supersede
        // the earlier one instead of sitting beside it.
        //
        // The cost is that two genuinely different decisions about the same subject in one
        // conversation collapse, the later superseding the earlier. That is the intended
        // reading of a subject-keyed kind, the old revision stays readable, and the
        // contradiction is surfaced for the user to resolve.
        let sentenceTokens = Set(Tokenizer.tokens(in: extraction.text))
        let subject = conversationKeywords
            .lazy
            .map(Tokenizer.stem)
            .first { sentenceTokens.contains($0) }

        guard let subject else {
            // No shared topic: fall back to claim keying rather than collapsing every
            // unrelated decision in the conversation into one memory.
            return Tokenizer.dedupeKey(kind: kind, subject: nil, claim: extraction.text)
        }
        return "\(kind.rawValue)|subject|\(subject)"
    }

    // MARK: - Text

    static func title(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 90 {
            // Cut at a word boundary rather than mid-word.
            let cut = trimmed.prefix(90)
            if let space = cut.lastIndex(of: " ") {
                trimmed = String(cut[cut.startIndex..<space]) + "…"
            } else {
                trimmed = String(cut) + "…"
            }
        }
        return trimmed
    }

    static func detail(from group: [ExtractionSnapshot]) -> String {
        let unique = group
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String]()) { result, text in
                if !result.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    result.append(text)
                }
            }
        return unique.prefix(4).joined(separator: "\n")
    }

    // MARK: - Contradiction detection beyond the supersede chain

    /// Two memories of the same kind about the same subject where one negates the other.
    ///
    /// The supersede chain already catches a *changed* statement under the same key. This
    /// catches the other shape: two memories with different keys whose claims are near
    /// opposites — one carries a negation and their content words otherwise agree.
    static func contradicts(_ a: String, _ b: String) -> Bool {
        let negations: Set<String> = ["not", "no", "never", "dont", "doesnt", "didnt", "cant",
                                      "wont", "isnt", "arent", "wasnt", "werent", "stopped",
                                      "cancelled", "canceled"]

        let leftRaw = Set(a.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let rightRaw = Set(b.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))

        let leftNegated = !leftRaw.intersection(negations).isEmpty
        let rightNegated = !rightRaw.intersection(negations).isEmpty
        // Exactly one of them must be a negation, or they are simply two statements.
        guard leftNegated != rightNegated else { return false }

        let left = Set(Tokenizer.tokens(in: a))
        let right = Set(Tokenizer.tokens(in: b))
        guard left.count >= 2, right.count >= 2 else { return false }
        let overlap = Double(left.intersection(right).count)
        let smaller = Double(min(left.count, right.count))
        // They are about the same thing if most of the smaller one's content words appear
        // in the other.
        return (overlap / smaller) >= 0.6
    }
}
