import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Phrases one answer from snippets that have **already been retrieved**.
///
/// The important property is what it is *not*: the model never sees the database, never
/// runs a query, and never runs over more than the handful of snippets search already
/// ranked. That is the rule the spec asks for — no LLM over the whole database per search —
/// and it is also what keeps answering fast and cheap.
///
/// Grounding is enforced three ways:
/// 1. The prompt contains numbered excerpts and nothing else.
/// 2. The instructions forbid using outside knowledge and require citing excerpt numbers.
/// 3. The parser **drops any answer that cites nothing**, so an ungrounded sentence never
///    reaches the user. When that happens `AnswerService` falls back to quoting.
struct FoundationModelAnswerer {
    struct GroundedAnswer: Hashable, Sendable {
        var text: String
        /// 1-based excerpt numbers the model claimed to use.
        var citedExcerpts: [Int]
    }

    private static let maximumExcerpts = 8
    private static let maximumExcerptCharacters = 500

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
        #else
        return false
        #endif
    }

    func answer(question: String, excerpts: [String]) async -> GroundedAnswer? {
        guard !excerpts.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            return await respond(question: question, excerpts: excerpts)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func respond(question: String, excerpts: [String]) async -> GroundedAnswer? {
        let session = LanguageModelSession(instructions: """
            You answer questions using ONLY the numbered excerpts you are given. The \
            excerpts come from automatic transcripts of the user's own conversations.

            Rules you must follow:
            - Use nothing but the excerpts. No outside knowledge, no assumptions, no \
            filling in gaps.
            - If the excerpts do not answer the question, reply with exactly: INSUFFICIENT
            - Quote or closely paraphrase. Do not editorialise and do not give advice.
            - Transcripts contain recognition errors. If an excerpt is too garbled to use, \
            ignore it rather than guessing what it meant.

            Reply in exactly this format and nothing else:
            ANSWER: <one to three sentences>
            USED: <comma-separated excerpt numbers you actually used>
            """)

        let prompt = Self.prompt(question: question, excerpts: excerpts)
        do {
            let response = try await session.respond(to: prompt)
            return Self.parse(response.content)
        } catch {
            Log.model.notice("Grounded answer failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    // MARK: - Prompt and parsing (pure, so they are unit tested without the framework)

    static func prompt(question: String, excerpts: [String]) -> String {
        var lines = ["Question: \(question)", "", "Excerpts:"]
        for (index, excerpt) in excerpts.prefix(maximumExcerpts).enumerated() {
            let trimmed = excerpt.count > maximumExcerptCharacters
                ? String(excerpt.prefix(maximumExcerptCharacters)) + "…"
                : excerpt
            lines.append("\(index + 1). \(trimmed)")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns `nil` for `INSUFFICIENT`, for an unparseable reply, or — importantly — for an
    /// answer that cites no excerpt at all.
    static func parse(_ content: String) -> GroundedAnswer? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.uppercased().hasPrefix("INSUFFICIENT") else { return nil }

        var answer = ""
        var used: [Int] = []

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("ANSWER:") {
                answer = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("USED:") {
                used = String(line.dropFirst(5))
                    .split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
            } else if !answer.isEmpty && used.isEmpty {
                answer += " " + line
            }
        }

        guard !answer.isEmpty, answer.uppercased() != "INSUFFICIENT" else { return nil }
        // An answer with no citation is exactly the failure mode this whole type exists to
        // prevent.
        guard !used.isEmpty else { return nil }

        return GroundedAnswer(text: answer, citedExcerpts: used.sorted())
    }
}
