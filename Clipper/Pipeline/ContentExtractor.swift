import Foundation
import NaturalLanguage

/// What one transcript segment yielded.
struct ExtractionResult: Hashable, Sendable {
    var extractions: [ExtractionCandidate]
    var entities: [EntityCandidate]
    /// Content words, used for topic nodes and for conversation topic-shift detection.
    var keywords: [String]

    static let empty = ExtractionResult(extractions: [], entities: [], keywords: [])

    var isEmpty: Bool {
        extractions.isEmpty && entities.isEmpty && keywords.isEmpty
    }
}

/// Pulls structure out of transcribed speech using `NaturalLanguage` and `NSDataDetector`.
///
/// ## Why cue phrases and not a model
/// The classification here is lexical: a sentence is a decision because it contains "we
/// decided" or "let's", a task because it contains "need to". That is unglamorous, and it
/// is the right call for this layer:
///
/// - It is **deterministic**, so the same speech always produces the same extractions and
///   the dedupe keys stay stable across reprocessing.
/// - It is **free**, so it can run on every segment as it arrives without touching the
///   battery, leaving the language model for conversation-level summarisation where it
///   actually earns its cost.
/// - It is **inspectable**: a wrong extraction can be traced to a rule.
///
/// Every candidate carries a confidence that reflects how strong the cue was, and anything
/// weak is stored as `.uncertain`. Named entities come from `NLTagger`, which is a real
/// model, and date/time detection from `NSDataDetector`.
struct ContentExtractor {
    /// Cue phrases, ordered so the most specific kind wins. Each is a lowercase substring.
    private static let cues: [(kind: MemoryKind, phrases: [String], confidence: Double)] = [
        (.decision, ["we decided", "i decided", "we've decided", "let's go with", "we're going with",
                     "the plan is", "we'll use", "i'll use", "we should use", "decided to",
                     "final answer", "we agreed"], 0.72),
        (.task, ["need to", "needs to", "have to", "i should", "we should", "todo", "to do",
                 "action item", "i'll take care of", "can you", "make sure"], 0.6),
        (.reminder, ["remind me", "don't forget", "remember to", "note to self"], 0.75),
        (.goal, ["i want to", "we want to", "my goal", "our goal", "aiming to", "trying to",
                 "i'd like to"], 0.6),
        (.preference, ["i like", "i love", "i prefer", "i hate", "i don't like", "my favourite",
                       "my favorite", "i'd rather", "can't stand"], 0.68),
        (.idea, ["what if", "we could", "idea is", "an idea", "maybe we", "how about",
                 "it might be worth"], 0.55),
        (.event, ["meeting", "appointment", "deadline", "birthday", "flight", "on monday",
                  "on tuesday", "on wednesday", "on thursday", "on friday", "on saturday",
                  "on sunday", "next week", "tomorrow"], 0.5),
        (.relationship, ["my wife", "my husband", "my brother", "my sister", "my mum", "my mom",
                         "my dad", "my manager", "my boss", "my friend", "works with",
                         "my colleague"], 0.6),
        (.unresolved, ["not sure", "we still need to figure", "unclear", "open question",
                       "we never decided", "still deciding", "tbd"], 0.6),
    ]

    private static let questionOpeners: Set<String> = [
        "who", "what", "when", "where", "why", "how", "which", "whose",
        "do", "does", "did", "can", "could", "should", "would", "will", "is", "are", "was",
        "were", "have", "has", "am",
    ]

    /// Lexical classes that can be a topic keyword.
    private static let keywordClasses: Set<NLTag> = [.noun, .verb, .adjective]

    private let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    init() {}

    func extract(from text: String, occurredAt: Date) -> ExtractionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return .empty }

        var extractions: [ExtractionCandidate] = []
        var seen = Set<String>()

        for sentence in Self.sentences(in: trimmed) {
            let lower = sentence.lowercased()

            // Questions first: a question that also contains "we should" is still a
            // question, and filing it as a task would be wrong.
            if Self.isQuestion(lower) {
                append(&extractions, &seen,
                       ExtractionCandidate(kind: .question,
                                           text: sentence,
                                           confidence: 0.7,
                                           assertion: .stated))
                continue
            }

            var matched = false
            for cue in Self.cues {
                guard let phrase = cue.phrases.first(where: { lower.contains($0) }) else { continue }
                // A cue at the start of a sentence is stronger evidence than one buried in
                // a subordinate clause.
                let leading = lower.hasPrefix(phrase)
                append(&extractions, &seen,
                       ExtractionCandidate(kind: cue.kind,
                                           text: sentence,
                                           confidence: leading ? min(0.9, cue.confidence + 0.1) : cue.confidence,
                                           assertion: cue.confidence >= 0.6 ? .stated : .uncertain))
                matched = true
                break
            }

            if !matched, sentence.count >= 25 {
                // A declarative sentence long enough to be a claim rather than filler.
                append(&extractions, &seen,
                       ExtractionCandidate(kind: .claim,
                                           text: sentence,
                                           confidence: 0.4,
                                           assertion: .stated))
            }

            // Dates and times promote a sentence to an event, in addition to whatever else
            // it was classified as.
            if let dateDetector {
                let range = NSRange(sentence.startIndex..<sentence.endIndex, in: sentence)
                if dateDetector.firstMatch(in: sentence, options: [], range: range) != nil {
                    append(&extractions, &seen,
                           ExtractionCandidate(kind: .event,
                                               text: sentence,
                                               confidence: 0.62,
                                               assertion: .stated))
                }
            }
        }

        let entities = Self.entities(in: trimmed)
        let keywords = Self.keywords(in: trimmed)

        return ExtractionResult(extractions: Array(extractions.prefix(12)),
                                entities: entities,
                                keywords: keywords)
    }

    private func append(_ list: inout [ExtractionCandidate],
                        _ seen: inout Set<String>,
                        _ candidate: ExtractionCandidate) {
        let key = "\(candidate.kind.rawValue)|\(candidate.text.lowercased())"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        list.append(candidate)
    }

    // MARK: - Sentences

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 4 { result.append(sentence) }
            return result.count < 40
        }
        // Speech often arrives without punctuation, so the whole utterance is one
        // "sentence". That is fine — it just means one candidate per utterance.
        return result.isEmpty ? [text] : result
    }

    static func isQuestion(_ lowercased: String) -> Bool {
        if lowercased.hasSuffix("?") { return true }
        guard let first = lowercased.split(separator: " ").first else { return false }
        let word = String(first.trimmingCharacters(in: CharacterSet.alphanumerics.inverted))
        // An opener alone is weak; require the sentence to be long enough to be a real
        // question rather than "Is it." trailing off.
        return questionOpeners.contains(word) && lowercased.count >= 12
    }

    // MARK: - Entities

    /// Named entities from `NLTagger`. This is the one genuinely model-backed part of
    /// extraction, and it is why people and places get their own nodes.
    static func entities(in text: String) -> [EntityCandidate] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var found: [String: EntityCandidate] = [:]
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: options) { tag, range in
            guard let tag else { return true }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { return true }

            let kind: NodeKind
            switch tag {
            case .personalName: kind = .person
            case .placeName: kind = .place
            case .organizationName: kind = .project
            default: return true
            }

            let key = Tokenizer.normalizeName(value)
            guard !key.isEmpty else { return true }
            if found[key] == nil {
                // Speech recognition capitalises inconsistently, so entity confidence is
                // capped well below certainty.
                found[key] = EntityCandidate(name: value, kind: kind, confidence: 0.6)
            }
            return found.count < 12
        }

        return Array(found.values)
    }

    /// Content words for topic nodes, ranked by frequency then length.
    ///
    /// Lemmatised through `NLTagger` so "meetings" and "meeting" are one topic. Verbs and
    /// adjectives are included because conversation topics are often not nouns
    /// ("refactoring", "expensive").
    /// Topic words, most frequent first.
    ///
    /// The part-of-speech pass is the good one, but `NLTagger` returns nothing at all when
    /// a requested scheme has no model for the text's language — which is the case for
    /// `.lemma` in some environments, including the Simulator. Keyword extraction feeding
    /// the brain map, the subject keys and the summariser must not quietly become a no-op
    /// there, so a plain frequency count stands behind it. Same ordering, no model needed.
    static func keywords(in text: String, limit: Int = 8) -> [String] {
        var counts = taggedKeywords(in: text)
        if counts.isEmpty { counts = frequencyKeywords(in: text) }

        return counts
            .sorted { left, right in
                left.value != right.value ? left.value > right.value : left.key.count > right.key.count
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func taggedKeywords(in text: String) -> [String: Int] {
        // Only ask for schemes this device can actually serve; an unavailable one makes
        // the whole enumeration silent rather than degrading.
        let available = Set(NLTagger.availableTagSchemes(for: .word, language: .english))
        guard available.contains(.lexicalClass) else { return [:] }
        let wantsLemma = available.contains(.lemma)

        let tagger = NLTagger(tagSchemes: wantsLemma ? [.lexicalClass, .lemma] : [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]

        var counts: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: options) { tag, range in
            guard let tag, keywordClasses.contains(tag) else { return true }
            let surface = String(text[range]).lowercased()
            guard surface.count >= 4, !Tokenizer.stopwords.contains(surface) else { return true }

            let lemma = wantsLemma
                ? tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                : nil
            let term = (lemma?.lowercased()).flatMap { $0.count >= 3 ? $0 : nil } ?? surface
            counts[term, default: 0] += 1
            return true
        }
        return counts
    }

    /// Frequency of the words that are left once filler is removed. Surface forms rather
    /// than stems, so a node in the brain map is called "postgres" and not "postgre".
    private static func frequencyKeywords(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        for word in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let surface = String(word)
            guard surface.count >= 4, !Tokenizer.stopwords.contains(surface) else { continue }
            counts[surface, default: 0] += 1
        }
        return counts
    }

    /// Do two keyword sets describe different subjects?
    ///
    /// Jaccard overlap, with a floor on how much evidence is needed: two keywords in common
    /// out of three is not a topic shift, but nothing in common out of six is. Used by the
    /// conversation segmenter, so a false positive splits a conversation in two and a false
    /// negative merges two — both recoverable, neither silent.
    static func isTopicShift(from previous: [String], to next: [String]) -> Bool {
        let left = Set(previous)
        let right = Set(next)
        guard left.count >= 3, right.count >= 3 else { return false }
        let overlap = Double(left.intersection(right).count)
        let union = Double(left.union(right).count)
        guard union > 0 else { return false }
        return (overlap / union) < 0.12
    }
}
