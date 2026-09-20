import Foundation
import NaturalLanguage

/// Text → index terms.
///
/// Deliberately small and deterministic, because the index and the query must agree
/// exactly: any change here invalidates stored postings, which is why the reindex action
/// exists in Diagnostics.
///
/// `NLTokenizer` does the word splitting rather than a `CharacterSet` split, so contractions,
/// hyphenation and non-Latin scripts behave. Everything after that is folding, stopword
/// removal and a conservative suffix strip — not a real stemmer, on purpose: aggressive
/// stemming ruins proper nouns, and proper nouns are most of what this app searches for.
enum Tokenizer {
    /// Words carrying no retrieval value. Kept short: over-pruning hurts phrase search.
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "did", "do", "does",
        "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if", "in",
        "into", "is", "it", "its", "just", "like", "me", "my", "no", "not", "of", "on", "or",
        "our", "out", "she", "so", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "to", "too", "up", "us", "very", "was", "we", "were",
        "what", "when", "which", "who", "will", "with", "would", "you", "your", "um", "uh",
        "yeah", "okay", "ok", "right", "well", "know", "gonna", "kinda", "sorta",
    ]

    private static let minimumLength = 2

    /// Split, fold and filter. The single source of truth for what a term is.
    static func tokens(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = folded

        var result: [String] = []
        tokenizer.enumerateTokens(in: folded.startIndex..<folded.endIndex) { range, _ in
            let raw = String(folded[range])
            let cleaned = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard cleaned.count >= minimumLength, !stopwords.contains(cleaned) else { return true }
            // Pure punctuation or a stray symbol.
            guard cleaned.rangeOfCharacter(from: .alphanumerics) != nil else { return true }
            result.append(stem(cleaned))
            return true
        }
        return result
    }

    /// Conservative suffix stripping. Only applied to words long enough that the strip
    /// cannot collide with a different word.
    static func stem(_ token: String) -> String {
        guard token.count > 4 else { return token }
        for suffix in ["ing", "edly", "ies", "ied"] where token.hasSuffix(suffix) {
            let stripped = String(token.dropLast(suffix.count))
            if stripped.count >= 3 {
                return suffix == "ies" || suffix == "ied" ? stripped + "y" : stripped
            }
        }
        for suffix in ["ed", "ly", "es"] where token.hasSuffix(suffix) {
            let stripped = String(token.dropLast(suffix.count))
            if stripped.count >= 4 { return stripped }
        }
        if token.hasSuffix("s") && !token.hasSuffix("ss") {
            let stripped = String(token.dropLast())
            if stripped.count >= 4 { return stripped }
        }
        return token
    }

    struct Weighted {
        /// Unique term → normalised weight.
        let weights: [(String, Double)]
        let totalTokens: Int
    }

    /// Per-document term weights.
    ///
    /// Title terms count triple: a memory titled "Aurora launch date" should outrank a
    /// passing mention of Aurora in a long transcript. The `sqrt` length normalisation is
    /// the standard correction for long documents dominating on raw term frequency.
    static func weightedTokens(title: String, body: String) -> Weighted {
        let titleTokens = tokens(in: title)
        let bodyTokens = tokens(in: body)
        let total = titleTokens.count + bodyTokens.count
        guard total > 0 else { return Weighted(weights: [], totalTokens: 0) }

        var counts: [String: Double] = [:]
        for token in titleTokens { counts[token, default: 0] += 3 }
        for token in bodyTokens { counts[token, default: 0] += 1 }

        let normaliser = sqrt(Double(total))
        let weights = counts.map { ($0.key, $0.value / normaliser) }
        return Weighted(weights: weights, totalTokens: total)
    }

    /// Identity key for a brain-map node. Drops leading articles so "the Aurora project"
    /// and "Aurora project" are one node.
    static func normalizeName(_ name: String) -> String {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if let first = words.first, ["the", "a", "an", "my", "our"].contains(first) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// A stable dedupe key for a memory: kind, subject and the claim's content words.
    ///
    /// Sorting the content words means "Postgres for the database" and "the database will
    /// be Postgres" collapse to one key, which is what makes reinforcement work on real
    /// speech rather than only on identical phrasing.
    static func dedupeKey(kind: MemoryKind, subject: String?, claim: String) -> String {
        let subjectPart = subject.map { normalizeName($0) } ?? ""
        let claimTokens = Array(Set(tokens(in: claim))).sorted().prefix(8).joined(separator: "-")
        return "\(kind.rawValue)|\(subjectPart)|\(claimTokens)"
    }

    /// Does the text contain this phrase, ignoring case and diacritics? Used to promote
    /// exact-phrase matches above bag-of-words matches.
    static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }
        return text.range(of: trimmed,
                          options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
