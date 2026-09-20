import AppIntents
import Foundation

// Clipper's query surface for Shortcuts and Siri.
//
// These intents read the database, so they live in the app target. The four transport
// intents (start/stop/pause/resume) live in Shared/ instead, because a Live Activity
// button needs them compiled into the widget extension as well - see
// ClipperTransportIntents.swift.

// MARK: - Memory queries

struct SearchMemoriesIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Memories"
    static var description = IntentDescription(
        "Searches everything Clipper has heard and answers with what it actually has."
    )
    /// Opening the app is the point: the answer comes with its evidence, and evidence is
    /// not something to read out of context.
    static var openAppWhenRun = true

    @Parameter(title: "What to look for", requestValueDialog: "What should I look for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Clipper for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AnswerService.shared.answer(query)
        AppRouter.shared.handle(.search(query))

        guard !answer.insufficientEvidence else {
            return .result(dialog: "Clipper has nothing recorded about that.")
        }
        let count = answer.hits.count
        let dialog = "\(count) result\(count == 1 ? "" : "s"). \(Self.spoken(answer))"
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// Keep the spoken form short, and keep the honesty label in it — an uncertain answer
    /// read aloud with no qualifier is the worst version of this feature.
    static func spoken(_ answer: AnswerDTO) -> String {
        let prefix: String
        switch answer.assertion {
        case .stated: prefix = ""
        case .summarised: prefix = "From a summary: "
        case .inferred: prefix = "Inferred: "
        case .uncertain: prefix = "Uncertain: "
        case .contradictory: prefix = "Your statements conflict. "
        case .unsupported: prefix = "Unsupported: "
        }
        let body = answer.answer.replacingOccurrences(of: "\n", with: " ")
        return prefix + String(body.prefix(240))
    }
}

struct MemoriesAboutIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Memories About"
    static var description = IntentDescription(
        "Finds what Clipper heard about a person, topic or project."
    )
    static var openAppWhenRun = true

    @Parameter(title: "Person or topic", requestValueDialog: "Who or what should I look up?")
    var subject: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find Clipper memories about \(\.$subject)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ClipperStore.shared
        // A matching brain-map node gives a much better result than a raw text search,
        // because it carries the node's own summary and its edges.
        if let node = await store.nodes(matching: subject, limit: 1).first {
            AppRouter.shared.handle(.node(node.id))
            if let summaryID = node.summaryID, let summary = await store.summary(id: summaryID) {
                return .result(dialog: IntentDialog(stringLiteral: "\(node.name): \(summary.text)"))
            }
            return .result(dialog: IntentDialog(
                stringLiteral: "\(node.name), mentioned \(node.mentionCount) times. Opening it now."
            ))
        }

        let answer = await AnswerService.shared.answer(subject)
        AppRouter.shared.handle(.search(subject))
        guard !answer.insufficientEvidence else {
            return .result(dialog: "Clipper has nothing about that.")
        }
        return .result(dialog: IntentDialog(stringLiteral: SearchMemoriesIntent.spoken(answer)))
    }
}

struct OpenTodayTimelineIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Today's Timeline"
    static var description = IntentDescription("Opens everything Clipper heard today.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppRouter.shared.handle(.today)
        return .result()
    }
}

struct ShowRecentSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Recent Summary"
    static var description = IntentDescription("Reads back Clipper's most recent summary.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let summary = await ClipperStore.shared.latestSummary() else {
            return .result(dialog: "Clipper has not written a summary yet.")
        }
        let age = summary.updatedAt.formatted(.relative(presentation: .named))
        return .result(dialog: IntentDialog(
            stringLiteral: "\(summary.title), \(age). \(summary.text)"
        ))
    }
}

struct OpenMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Memory"
    static var description = IntentDescription("Opens one of Clipper's memories, with its evidence.")
    static var openAppWhenRun = true

    @Parameter(title: "Memory")
    var memory: MemoryAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$memory) in Clipper")
    }

    func perform() async throws -> some IntentResult {
        AppRouter.shared.handle(.memory(memory.id))
        return .result()
    }
}

// MARK: - Entity

/// Makes individual memories addressable from Shortcuts and Siri.
struct MemoryAppEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Memory")
    }

    static var defaultQuery = MemoryAppEntityQuery()

    var id: UUID
    var title: String
    var kindLabel: String
    var assertionLabel: String

    var displayRepresentation: DisplayRepresentation {
        // The honesty label travels with the entity, so a Shortcuts picker does not present
        // an uncertain memory as a plain fact.
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(kindLabel) · \(assertionLabel)")
    }

    init(memory: MemoryDTO) {
        self.id = memory.id
        self.title = memory.title
        self.kindLabel = memory.kind.title
        self.assertionLabel = memory.assertion.title
    }
}

struct MemoryAppEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [MemoryAppEntity] {
        await ClipperStore.shared.memories(ids: identifiers).map(MemoryAppEntity.init)
    }

    func entities(matching string: String) async throws -> [MemoryAppEntity] {
        let outcome = await AnswerService.shared.runSearch(string, limit: 20)
        let ids = outcome.hits.filter { $0.kind == .memory }.map(\.refID)
        return await ClipperStore.shared.memories(ids: ids).map(MemoryAppEntity.init)
    }

    func suggestedEntities() async throws -> [MemoryAppEntity] {
        await ClipperStore.shared.importantMemories(limit: 10).map(MemoryAppEntity.init)
    }
}
