import Foundation

// Value types that cross the boundary out of the database.
//
// `@Model` objects are bound to the `ModelContext` that fetched them and are not safe to
// hand to another actor or to hold in view state. Everything the UI and the pipeline see
// is therefore a plain struct, copied out at fetch time. That single rule removes the
// entire class of SwiftData concurrency crashes, and it makes every screen trivially
// previewable and testable with synthetic data.

struct SessionDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let speechSeconds: Double
    let utteranceCount: Int
    let interruptionCount: Int
    let inputName: String?
    let usedBuiltInMic: Bool

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var isOpen: Bool { endedAt == nil }
}

struct SpeakerDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String?
    let isNamed: Bool
    let sampleCount: Int
    let totalSpeechSeconds: Double
    let identityConfidence: Double
    let promptState: SpeakerPromptState
    let colorIndex: Int
    let createdAt: Date
    let previousNames: [String]

    var label: String { displayName ?? "Unknown voice" }
}

struct TranscriptLineDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let conversationID: UUID?
    let speakerID: UUID?
    let speakerLabel: String
    let speakerColorIndex: Int
    let startedAt: Date
    let endedAt: Date
    let text: String
    let confidence: Double
    let speakerConfidence: Double
    let audioQuality: Double
    let assertion: AssertionKind
    let processingState: ProcessingState
    let isLowConfidence: Bool
    let audioSegmentID: UUID?
    let audioAvailable: Bool
    let wordTimings: [WordTiming]
    let wasEdited: Bool

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    /// True when the speaker is a cluster we have no name for.
    var speakerIsUnknown: Bool { speakerID == nil || speakerLabel == "Unknown voice" }
}

struct ConversationDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let title: String
    let segmentCount: Int
    let speechSeconds: Double
    let confidence: Double
    let importance: Double
    let isOpen: Bool
    let speakerLabels: [String]
    let summaryText: String?
    let summaryID: UUID?
    let topicNames: [String]
    /// Brain-map nodes this conversation touched. Carried on the DTO so the summarisation
    /// stage does not need a second round trip to find them.
    let nodeIDs: [UUID]
    let speakerIDs: [UUID]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

struct MemoryDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: MemoryKind
    let title: String
    let detail: String
    let confidence: Double
    let assertion: AssertionKind
    let importance: Double
    let createdAt: Date
    let updatedAt: Date
    let firstSeenAt: Date
    let lastSeenAt: Date
    let occurrenceCount: Int
    let revision: Int
    let supersedesID: UUID?
    let supersededByID: UUID?
    let isArchived: Bool
    let isUserEdited: Bool
    let sourceKind: SourceKind
    let sourceIDs: [UUID]
    let nodeIDs: [UUID]
    /// The voice this memory is about, when it is about a person's own statement.
    let subjectSpeakerID: UUID?
    let strength: Double

    var isCurrent: Bool { supersededByID == nil && !isArchived }
    /// Nothing supports this. Rendered as a warning, never hidden.
    var isUnsupported: Bool { sourceIDs.isEmpty && !isUserEdited }
}

struct SummaryDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let scope: SummaryScope
    let key: String
    let title: String
    let text: String
    let bullets: [String]
    let createdAt: Date
    let updatedAt: Date
    let revision: Int
    let periodStart: Date
    let periodEnd: Date
    let confidence: Double
    let assertion: AssertionKind
    let sourceIDs: [UUID]
    /// `foundationModels` or `extractive`.
    let generator: String
}

struct GraphNodeDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: NodeKind
    let name: String
    let mentionCount: Int
    let importance: Double
    let lastMentionedAt: Date
    let refID: UUID?
    let summaryID: UUID?
}

struct GraphEdgeDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceNodeID: UUID
    let targetNodeID: UUID
    let kind: EdgeKind
    let weight: Double
    let confidence: Double
    let evidenceIDs: [UUID]
    let evidenceKind: SourceKind

    var isExplainable: Bool { !evidenceIDs.isEmpty }
}

/// A node plus its immediate neighbourhood — what the brain map actually renders. Never a
/// whole graph.
struct SubgraphDTO: Hashable, Sendable {
    let focus: GraphNodeDTO
    let neighbours: [GraphNodeDTO]
    let edges: [GraphEdgeDTO]
    /// True when neighbours were cut off by the page size, so the UI can offer "expand".
    let hasMore: Bool
}

struct ContradictionDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let explanation: String
    let detectedAt: Date
    let confidence: Double
    let isResolved: Bool
    let earlier: MemoryDTO?
    let later: MemoryDTO?
}

/// One search result, with everything needed to rank it and to explain why it matched.
struct SearchHitDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: DocumentKind
    let refID: UUID
    let conversationID: UUID?
    let title: String
    let snippet: String
    let timestamp: Date
    let assertion: AssertionKind
    let confidence: Double
    let importance: Double
    /// Final blended score.
    let score: Double
    /// Component scores, shown in Diagnostics so ranking is inspectable rather than magic.
    let lexicalScore: Double
    let semanticScore: Double
    let recencyScore: Double
    let matchedTokens: [String]
    let speakerLabels: [String]

    var deepLink: ClipperDeepLink {
        switch kind {
        case .transcriptSegment, .conversation: return .conversation(conversationID ?? refID)
        case .memory, .summary: return .memory(refID)
        case .speaker: return .speaker(refID)
        case .node: return .node(refID)
        }
    }
}

/// The traceable chain the spec requires:
/// answer → memory → conversation → transcript segment → timestamp → audio source.
struct EvidenceChainDTO: Identifiable, Hashable, Sendable {
    var id: UUID { leaf.id }
    let memory: MemoryDTO?
    let summary: SummaryDTO?
    let conversation: ConversationDTO?
    let leaf: TranscriptLineDTO
    /// Present only if the evidence audio still exists.
    let audioURL: URL?
    let audioExpired: Bool
}

/// The answer to a question, with its support and its honesty labels.
struct AnswerDTO: Hashable, Sendable {
    let question: String
    let answer: String
    /// How the answer relates to the evidence. `.unsupported` means say so, loudly.
    let assertion: AssertionKind
    let confidence: Double
    let chains: [EvidenceChainDTO]
    let hits: [SearchHitDTO]
    /// Set when there was not enough evidence to answer at all.
    let insufficientEvidence: Bool
    let generator: String
}

/// Counts for Diagnostics and the widget.
struct StoreStatsDTO: Hashable, Sendable {
    var sessions = 0
    var audioSegments = 0
    var transcriptSegments = 0
    var conversations = 0
    var speakers = 0
    var namedSpeakers = 0
    var memories = 0
    var summaries = 0
    var contradictions = 0
    var openContradictions = 0
    var nodes = 0
    var edges = 0
    var documents = 0
    var postings = 0
    var pendingJobs = 0
    var failedJobs = 0
}
