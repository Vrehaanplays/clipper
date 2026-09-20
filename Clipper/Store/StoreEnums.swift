import Foundation

// Every enum here is persisted as its `rawValue` string rather than as a Codable enum.
// Two reasons: a raw string survives adding and renaming cases without a store migration,
// and `#Predicate` can compare it directly, which a Codable enum attribute cannot.

/// Where a record is in the pipeline. This is the resume point after a relaunch: anything
/// not `complete`, `skipped` or `failed` is picked up again.
enum ProcessingState: String, Codable, CaseIterable, Sendable {
    case pending
    case enhancing
    case classifying
    case transcribing
    case attributing
    case extracting
    case complete
    /// Deliberately not processed — below the confidence floor, or transcription is off.
    case skipped
    case failed

    var isTerminal: Bool {
        self == .complete || self == .skipped || self == .failed
    }

    var title: String {
        switch self {
        case .pending: return "Queued"
        case .enhancing: return "Cleaning audio"
        case .classifying: return "Checking audio"
        case .transcribing: return "Transcribing"
        case .attributing: return "Identifying speaker"
        case .extracting: return "Extracting"
        case .complete: return "Done"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }
}

/// How strongly a piece of information is claimed. Nothing in Clipper is stored without
/// one of these, and the UI always renders it.
enum AssertionKind: String, Codable, CaseIterable, Sendable {
    /// Said out loud, in the transcript, in these words.
    case stated
    /// Condensed from things that were said.
    case summarised
    /// Not said; concluded from what was said.
    case inferred
    /// Recognised but not trusted — low confidence, ambiguous, or an unknown speaker.
    case uncertain
    /// Directly conflicts with other stored information.
    case contradictory
    /// Retained but with no supporting source. Should not normally exist; if it does, the
    /// UI says so.
    case unsupported

    var title: String {
        switch self {
        case .stated: return "Directly stated"
        case .summarised: return "Summarised"
        case .inferred: return "Inferred"
        case .uncertain: return "Uncertain"
        case .contradictory: return "Contradictory"
        case .unsupported: return "Unsupported"
        }
    }

    var symbolName: String {
        switch self {
        case .stated: return "quote.opening"
        case .summarised: return "text.alignleft"
        case .inferred: return "arrow.triangle.branch"
        case .uncertain: return "questionmark.circle"
        case .contradictory: return "exclamationmark.2"
        case .unsupported: return "exclamationmark.triangle"
        }
    }
}

/// What kind of record an id in a provenance list points at.
enum SourceKind: String, Codable, CaseIterable, Sendable {
    case audioSegment
    case transcriptSegment
    case conversation
    case summary
    case memory
    case manual
}

/// The curated-memory taxonomy. Covers both the durable-memory layer and the content
/// classification the extractor applies.
enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case fact
    case preference
    case goal
    case project
    case decision
    case event
    case relationship
    case pattern
    case idea
    case question
    case task
    case reminder
    case person
    case place
    case topic
    case claim
    case conversation
    case unresolved

    var title: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .goal: return "Goal"
        case .project: return "Project"
        case .decision: return "Decision"
        case .event: return "Event"
        case .relationship: return "Relationship"
        case .pattern: return "Pattern"
        case .idea: return "Idea"
        case .question: return "Question"
        case .task: return "Task"
        case .reminder: return "Reminder"
        case .person: return "Person"
        case .place: return "Place"
        case .topic: return "Topic"
        case .claim: return "Claim"
        case .conversation: return "Conversation"
        case .unresolved: return "Unresolved"
        }
    }

    var symbolName: String {
        switch self {
        case .fact: return "checkmark.seal"
        case .preference: return "heart"
        case .goal: return "target"
        case .project: return "folder"
        case .decision: return "signpost.right"
        case .event: return "calendar"
        case .relationship: return "person.2"
        case .pattern: return "repeat"
        case .idea: return "lightbulb"
        case .question: return "questionmark.bubble"
        case .task: return "checklist"
        case .reminder: return "bell"
        case .person: return "person"
        case .place: return "mappin"
        case .topic: return "tag"
        case .claim: return "text.bubble"
        case .conversation: return "bubble.left.and.bubble.right"
        case .unresolved: return "questionmark.folder"
        }
    }

    /// Kinds that appear on the "unresolved items" screen.
    static let unresolvedKinds: [MemoryKind] = [.question, .unresolved, .task, .reminder]
}

/// Brain-map node types.
enum NodeKind: String, Codable, CaseIterable, Sendable {
    case person
    case topic
    case project
    case place
    case event
    case concept
    case claim
    case memory
    case summary
    case conversation

    var title: String {
        switch self {
        case .person: return "Person"
        case .topic: return "Topic"
        case .project: return "Project"
        case .place: return "Place"
        case .event: return "Event"
        case .concept: return "Concept"
        case .claim: return "Claim"
        case .memory: return "Memory"
        case .summary: return "Summary"
        case .conversation: return "Conversation"
        }
    }

    var symbolName: String {
        switch self {
        case .person: return "person.circle"
        case .topic: return "tag.circle"
        case .project: return "folder.circle"
        case .place: return "mappin.circle"
        case .event: return "calendar.circle"
        case .concept: return "lightbulb.circle"
        case .claim: return "text.bubble"
        case .memory: return "brain"
        case .summary: return "doc.text"
        case .conversation: return "bubble.left.and.bubble.right"
        }
    }
}

/// Brain-map edge types. Every edge carries the evidence that produced it.
enum EdgeKind: String, Codable, CaseIterable, Sendable {
    /// A conversation or transcript mentioned this node.
    case mentions
    /// This node is the subject of that one.
    case about
    /// A person took part in a conversation.
    case participatedIn
    /// Co-occurrence strong enough to be worth showing.
    case relatedTo
    /// Evidence backs a claim or memory.
    case supports
    /// Two records disagree.
    case contradicts
    /// Containment: a topic inside a project, an event inside a day.
    case partOf
    /// Derived from — a summary from a conversation, a memory from a summary.
    case derivedFrom
    /// A specific person said this.
    case saidBy

    var label: String {
        switch self {
        case .mentions: return "mentions"
        case .about: return "is about"
        case .participatedIn: return "took part in"
        case .relatedTo: return "relates to"
        case .supports: return "supports"
        case .contradicts: return "contradicts"
        case .partOf: return "is part of"
        case .derivedFrom: return "derived from"
        case .saidBy: return "said by"
        }
    }
}

/// The hierarchy of summaries.
enum SummaryScope: String, Codable, CaseIterable, Sendable {
    case conversation
    case session
    case day
    case week
    case topic
    case project

    var title: String {
        switch self {
        case .conversation: return "Conversation"
        case .session: return "Session"
        case .day: return "Day"
        case .week: return "Week"
        case .topic: return "Topic"
        case .project: return "Project"
        }
    }
}

/// Background work items, persisted so a relaunch resumes rather than restarts.
enum JobKind: String, Codable, CaseIterable, Sendable {
    case processUtterance
    case closeConversation
    case rollupDay
    case rollupWeek
    case rollupTopic
    case reindexDocument
    case retentionSweep
}

enum JobState: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case done
    case failed
    case cancelled
}

/// What an indexed document represents, so search can filter by type and deep-link back.
enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case transcriptSegment
    case conversation
    case summary
    case memory
    case speaker
    case node
}
