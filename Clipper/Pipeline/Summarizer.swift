import Foundation
import NaturalLanguage

/// What a summariser is asked to condense.
struct SummarizationInput: Hashable, Sendable {
    /// Speaker-labelled lines, in order.
    var lines: [String]
    /// What is being summarised, for the prompt and the title.
    var scope: SummaryScope
    /// Topic keywords already extracted, so the summariser does not have to rediscover them.
    var keywords: [String]
    var speakerLabels: [String]
    var periodStart: Date
    var periodEnd: Date

    var joinedText: String { lines.joined(separator: "\n") }

    var isSubstantial: Bool {
        lines.count >= 2 || joinedText.count >= 120
    }
}

protocol Summarizing: Sendable {
    var identifier: String { get }
    func isAvailable() async -> Bool
    func summarize(_ input: SummarizationInput) async -> SummaryDraft?
}

/// The fallback, and the floor on quality: a purely extractive summariser.
///
/// It selects sentences rather than writing them, which has one decisive property for this
/// app — **it cannot hallucinate.** Every word it outputs was said. When the language model
/// is unavailable (older OS, model not downloaded, device under memory pressure) the result
/// is plainer but never wrong, and it is labelled `extractive` so the user knows which
/// produced what.
///
/// Scoring is keyword overlap, length and position: sentences that use the conversation's
/// own topic words, are long enough to carry content, and appear early (where people state
/// the subject) or late (where they conclude).
struct ExtractiveSummarizer: Summarizing {
    let identifier = "extractive"

    func isAvailable() async -> Bool { true }

    func summarize(_ input: SummarizationInput) async -> SummaryDraft? {
        let text = input.joinedText
        guard !text.isEmpty else { return nil }
        // The floor lives here as well as in the pool, so no caller can talk the
        // summariser into padding a single line of filler into a memory.
        guard input.isSubstantial else { return nil }

        let sentences = ContentExtractor.sentences(in: text)
        guard !sentences.isEmpty else { return nil }

        let keywords = input.keywords.isEmpty
            ? ContentExtractor.keywords(in: text, limit: 8)
            : input.keywords
        let keywordSet = Set(keywords)

        var scored: [(index: Int, sentence: String, score: Double)] = []
        for (index, sentence) in sentences.enumerated() {
            let tokens = Set(Tokenizer.tokens(in: sentence))
            guard !tokens.isEmpty else { continue }

            let overlap = Double(tokens.intersection(keywordSet).count)
            let keywordScore = keywordSet.isEmpty ? 0 : overlap / Double(min(6, keywordSet.count))
            // Favour 60–220 characters: shorter is filler, longer is usually two thoughts.
            let length = Double(sentence.count)
            let lengthScore = length < 30 ? 0.1 : min(1, 220 / max(length, 60))
            let position = Double(index) / Double(max(1, sentences.count - 1))
            let positionScore = max(1 - position * 1.6, position * 0.6)

            scored.append((index, sentence,
                           0.55 * keywordScore + 0.25 * lengthScore + 0.2 * positionScore))
        }

        guard !scored.isEmpty else { return nil }

        let bulletCount = min(5, max(2, sentences.count / 3))
        let bullets = scored
            .sorted { $0.score > $1.score }
            .prefix(bulletCount)
            // Back into the order they were said, so the summary reads as a narrative.
            .sorted { $0.index < $1.index }
            .map { Self.tidy($0.sentence) }

        let title = Self.title(keywords: keywords, scope: input.scope, fallback: bullets.first)
        let summary = bullets.joined(separator: " ")

        return SummaryDraft(title: title,
                            text: summary,
                            bullets: bullets,
                            // Deliberately modest: selecting sentences is not understanding
                            // them.
                            confidence: 0.5,
                            generator: identifier)
    }

    static func tidy(_ sentence: String) -> String {
        var result = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading speaker label, which is in the input for the model's benefit but
        // reads badly in a bullet.
        if let colon = result.firstIndex(of: ":"),
           result.distance(from: result.startIndex, to: colon) <= 24 {
            let after = result[result.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { result = after }
        }
        if result.count > 240 {
            result = String(result.prefix(237)) + "…"
        }
        return result
    }

    static func title(keywords: [String], scope: SummaryScope, fallback: String?) -> String {
        let leading = keywords.prefix(3)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: ", ")
        if !leading.isEmpty { return leading }
        if let fallback {
            return String(fallback.prefix(56))
        }
        return scope.title
    }
}

/// Picks the best summariser available and records which one ran.
///
/// The language model is tried first when the user has left it on; the extractive
/// summariser is not a degraded mode so much as a guaranteed one. Both outcomes are stored
/// with their `generator`, so the UI can be honest about provenance.
actor SummarizerPool {
    static let shared = SummarizerPool()

    private let extractive = ExtractiveSummarizer()
    private let onDevice = FoundationModelSummarizer()

    private var languageModelAvailable: Bool?

    func summarize(_ input: SummarizationInput, preferLanguageModel: Bool) async -> SummaryDraft? {
        // Nothing to condense. A "summary" of one filler line is noise wearing a
        // provenance label, and the caller treats nil as "no summary for this", which is
        // the honest outcome.
        guard input.isSubstantial else { return nil }

        if preferLanguageModel {
            if languageModelAvailable == nil {
                languageModelAvailable = await onDevice.isAvailable()
                Log.model.notice("Language model available: \(self.languageModelAvailable == true)")
            }
            if languageModelAvailable == true {
                let (draft, elapsed) = await Log.timedAsync("summarize.languageModel") {
                    await onDevice.summarize(input)
                }
                if let draft {
                    Log.model.debug("Language model summary in \(String(format: "%.2f", elapsed))s")
                    return draft
                }
                // One failure does not mean permanently unavailable (memory pressure,
                // guardrails), so the flag is not cleared — but this summary falls back.
                Log.model.notice("Language model declined; falling back to extractive")
            }
        }

        return await extractive.summarize(input)
    }

    /// For Diagnostics. `statusDescription` already reports the reason when unavailable.
    func modelStatus() -> String {
        onDevice.statusDescription
    }
}
