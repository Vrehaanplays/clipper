import Foundation
import NaturalLanguage

/// Sentence vectors for semantic search, from `NLEmbedding`.
///
/// Apple ships the model with the OS, so there is nothing to download, nothing to bundle
/// and no network call. The trade-off is real and worth stating: `NLEmbedding`'s sentence
/// space is far weaker than a modern transformer embedding, so semantic search here is a
/// *supplement* to the lexical index, never a replacement. The blend weights in
/// `SearchService` reflect that.
///
/// `NLEmbedding` is not documented as thread-safe, so access is serialised behind an actor.
actor Embedder {
    static let shared = Embedder()

    private var sentenceEmbedding: NLEmbedding?
    private var didAttemptLoad = false

    /// Number of dimensions, or 0 when no embedding model is available on this device.
    var dimensions: Int {
        load()?.dimension ?? 0
    }

    var isAvailable: Bool {
        load() != nil
    }

    private func load() -> NLEmbedding? {
        if let sentenceEmbedding { return sentenceEmbedding }
        guard !didAttemptLoad else { return nil }
        didAttemptLoad = true
        // Sentence embeddings exist for a subset of languages; fall back to English rather
        // than giving up on semantic search entirely.
        let language = NLLanguage(Locale.current.language.languageCode?.identifier ?? "en")
        sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english)
        if sentenceEmbedding == nil {
            Log.model.notice("No sentence embedding model available; search will be lexical only")
        }
        return sentenceEmbedding
    }

    /// Embed a short piece of text. Returns an empty vector when unavailable, which every
    /// caller treats as "no semantic opinion" rather than as an error.
    func vector(for text: String) -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, let embedding = load() else { return [] }

        // One sentence: straight lookup.
        if trimmed.count <= 240 {
            guard let vector = embedding.vector(for: trimmed) else { return [] }
            return VectorMath.normalized(vector.map(Float.init))
        }

        // Longer text: mean of its sentence vectors, capped so a 30-minute transcript
        // cannot turn one embedding call into hundreds.
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            sentences.append(String(trimmed[range]))
            return sentences.count < 12
        }

        var accumulated: [Float] = []
        var counted = 0
        for sentence in sentences {
            guard let vector = embedding.vector(for: sentence) else { continue }
            let floats = vector.map(Float.init)
            if accumulated.isEmpty {
                accumulated = floats
            } else if accumulated.count == floats.count {
                for i in 0..<accumulated.count { accumulated[i] += floats[i] }
            }
            counted += 1
        }
        guard counted > 0 else { return [] }
        return VectorMath.normalized(accumulated.map { $0 / Float(counted) })
    }

    /// Nearest-neighbour words, used to widen a query that found nothing. Bounded by
    /// `limit` and only ever called on a failed search.
    func relatedTerms(for word: String, limit: Int = 4) -> [String] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return [] }
        return embedding.neighbors(for: word.lowercased(), maximumCount: limit).map(\.0)
    }
}
