import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarisation with Apple's on-device foundation model, when the device has one.
///
/// Everything about this type is defensive, for three reasons that are all real:
///
/// 1. **The framework may not exist in the SDK** the project is compiled against — hence
///    `#if canImport`. The app must build on an older Xcode and simply not have this path.
/// 2. **The model may not exist on the device**: an ineligible device, Apple Intelligence
///    switched off, or the model still downloading. `availability` is checked every time,
///    not cached forever.
/// 3. **A request can be declined** by the model's own guardrails, or fail under memory
///    pressure. A `nil` return is normal, and `SummarizerPool` falls back to the extractive
///    summariser rather than showing the user nothing.
///
/// The prompt is written to suppress invention: the model is told, explicitly, to use only
/// what is in the transcript and to say so when there is not enough. Output is parsed
/// strictly, and anything unparseable is discarded rather than guessed at — a garbled
/// summary would be stored with provenance implying it came from the user's own words.
struct FoundationModelSummarizer: Summarizing {
    let identifier = "foundationModels"

    /// Prompts are capped so one long conversation cannot blow the context window.
    private static let maximumPromptCharacters = 6_000

    var statusDescription: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "On-device language model available"
            case .unavailable(let reason):
                return "On-device language model unavailable: \(Self.describe(reason))"
            @unknown default:
                return "On-device language model status unknown"
            }
        }
        return "On-device language model needs iOS 26 or later"
        #else
        return "Built against an SDK without Foundation Models — summaries are extractive"
        #endif
    }

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

    func summarize(_ input: SummarizationInput) async -> SummaryDraft? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            return await respond(to: Self.prompt(for: input))
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func respond(to prompt: String) async -> SummaryDraft? {
        // The instructions are an inline literal rather than a stored constant so the call
        // site works whether the parameter takes a `String` or a string-literal type.
        let session = LanguageModelSession(instructions: """
            You summarise transcripts of conversations that a personal memory app recorded \
            from a phone microphone.

            Rules you must follow:
            - Use only information that appears in the transcript. Never add facts, names, \
            dates or conclusions that are not there.
            - The transcript comes from automatic speech recognition and contains errors, \
            repeated words and half-finished sentences. Do not try to repair meaning you \
            cannot see; ignore fragments you cannot interpret.
            - If there is not enough content to summarise, reply with exactly: INSUFFICIENT
            - Never address the reader, never give advice, never speculate about feelings \
            or intentions.

            Reply in exactly this format and nothing else:
            TITLE: <under 60 characters, naming the subject>
            SUMMARY: <one or two sentences, plain past tense>
            - <a key point, in the speakers' own terms>
            - <another key point>
            """)

        do {
            let response = try await session.respond(to: prompt)
            return Self.parse(response.content)
        } catch {
            Log.model.notice("Language model request failed: \(error.localizedDescription)")
            return nil
        }
    }

    @available(iOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "this device does not support it"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in Settings"
        case .modelNotReady:
            return "the model is still downloading"
        @unknown default:
            return "unknown reason"
        }
    }
    #endif

    // MARK: - Prompt and parsing (testable without the framework)

    static func prompt(for input: SummarizationInput) -> String {
        var header = "Transcript of a \(input.scope.title.lowercased())"
        if !input.speakerLabels.isEmpty {
            header += " between \(input.speakerLabels.joined(separator: ", "))"
        }
        header += "."
        if !input.keywords.isEmpty {
            header += " Topics detected: \(input.keywords.prefix(6).joined(separator: ", "))."
        }

        var body = input.joinedText
        if body.count > maximumPromptCharacters {
            // Keep the beginning and the end: people state the subject early and conclude
            // late, and the middle of a long conversation is the most redundant part.
            let half = maximumPromptCharacters / 2
            let start = body.prefix(half)
            let end = body.suffix(half)
            body = start + "\n[…]\n" + end
        }

        return header + "\n\n" + body
    }

    /// Strict parser. Returns `nil` unless both a title and a summary came back, because a
    /// half-parsed response stored as a summary would be worse than no summary.
    static func parse(_ content: String) -> SummaryDraft? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.uppercased().hasPrefix("INSUFFICIENT") else { return nil }

        var title = ""
        var summary = ""
        var bullets: [String] = []

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.uppercased().hasPrefix("TITLE:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("SUMMARY:") {
                summary = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") {
                let bullet = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if bullet.count >= 4 { bullets.append(bullet) }
            } else if !summary.isEmpty && bullets.isEmpty {
                // A summary that wrapped onto a second line.
                summary += " " + line
            }
        }

        guard !title.isEmpty, !summary.isEmpty else { return nil }
        if title.count > 80 { title = String(title.prefix(77)) + "…" }

        return SummaryDraft(title: title,
                            text: summary,
                            bullets: Array(bullets.prefix(6)),
                            // Higher than extractive because it reads better, still well
                            // short of certain: it is a generated paraphrase, and the
                            // assertion stored alongside it is `.summarised`.
                            confidence: 0.7,
                            generator: "foundationModels")
    }
}
