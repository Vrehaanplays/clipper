import Foundation
import SwiftData

/// A durable piece of knowledge, built by aggregating extractions.
///
/// ### Nothing is overwritten
/// A memory that changes is never edited in place. A new row is written with
/// `supersedesID` pointing at the old one, the old one gets `supersededByID` and stays
/// readable. `revision` counts the chain. That is what makes "what changed between my
/// earlier and later statements?" answerable at all.
///
/// ### Deduplication
/// `dedupeKey` is a normalised form of kind + subject + claim. A second sighting of the
/// same thing bumps `occurrenceCount` and `lastSeenAt` and appends to `sourceIDs` rather
/// than creating a duplicate row — which is what stops a repeated statement from turning
/// into fifty memories.
@Model
final class MemoryRecord {
    #Index<MemoryRecord>([\.createdAt], [\.kindRaw], [\.dedupeKey], [\.isArchived], [\.lastSeenAt])

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var title: String
    var detail: String

    var confidence: Double
    var assertionRaw: String
    /// 0...1. Drives ordering on the "recent important memories" screen.
    var importance: Double

    var createdAt: Date
    var updatedAt: Date
    var firstSeenAt: Date
    var lastSeenAt: Date
    var occurrenceCount: Int
    var revision: Int

    var supersedesID: UUID?
    var supersededByID: UUID?
    /// Archived memories stay queryable but are out of the way.
    var isArchived: Bool
    /// True when the user, not the pipeline, wrote or corrected this.
    var isUserEdited: Bool

    var sourceKindRaw: String
    /// Every id that supports this memory. Never empty for a generated memory; if it is,
    /// the assertion is downgraded to `.unsupported` and the UI says so.
    var sourceIDs: [String]
    var nodeIDs: [String]
    var subjectSpeakerID: UUID?

    var dedupeKey: String
    @Attribute(.externalStorage) var embedding: Data?

    init(id: UUID = UUID(),
         kind: MemoryKind,
         title: String,
         detail: String = "",
         confidence: Double = 0.5,
         assertion: AssertionKind = .summarised,
         importance: Double = 0.3,
         createdAt: Date = Date(),
         firstSeenAt: Date = Date(),
         lastSeenAt: Date = Date(),
         occurrenceCount: Int = 1,
         revision: Int = 1,
         supersedesID: UUID? = nil,
         isArchived: Bool = false,
         isUserEdited: Bool = false,
         sourceKind: SourceKind = .transcriptSegment,
         sourceIDs: [String] = [],
         nodeIDs: [String] = [],
         subjectSpeakerID: UUID? = nil,
         dedupeKey: String = "",
         embedding: Data? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
        self.confidence = confidence
        self.assertionRaw = assertion.rawValue
        self.importance = importance
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrenceCount = occurrenceCount
        self.revision = revision
        self.supersedesID = supersedesID
        self.supersededByID = nil
        self.isArchived = isArchived
        self.isUserEdited = isUserEdited
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceIDs = sourceIDs
        self.nodeIDs = nodeIDs
        self.subjectSpeakerID = subjectSpeakerID
        self.dedupeKey = dedupeKey
        self.embedding = embedding
    }

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .fact }
        set { kindRaw = newValue.rawValue }
    }

    var assertion: AssertionKind {
        get { AssertionKind(rawValue: assertionRaw) ?? .summarised }
        set { assertionRaw = newValue.rawValue }
    }

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .transcriptSegment }
        set { sourceKindRaw = newValue.rawValue }
    }

    var isCurrent: Bool { supersededByID == nil && !isArchived }

    /// Evidence, recency and repetition combined. Used for ranking, never presented as
    /// truth on its own.
    var strength: Double {
        let evidence = min(1, Double(sourceIDs.count) / 4)
        let repetition = min(1, Double(occurrenceCount) / 5)
        return 0.5 * confidence + 0.3 * evidence + 0.2 * repetition
    }
}

/// One summary at one level of the hierarchy.
///
/// `key` identifies the thing summarised: a conversation UUID string, `2026-09-16` for a
/// day, `2026-W38` for a week, or a node UUID string for a topic or project. `scope` plus
/// `key` is therefore unique, which is what makes rollups idempotent — regenerating a day
/// updates one row instead of appending a second opinion.
@Model
final class SummaryRecord {
    #Index<SummaryRecord>([\.createdAt], [\.scopeRaw], [\.key], [\.updatedAt])

    @Attribute(.unique) var id: UUID
    var scopeRaw: String
    var key: String

    var title: String
    var text: String
    /// Bullet points, stored as JSON so the structure survives without a second table.
    @Attribute(.externalStorage) var bulletsData: Data?

    var createdAt: Date
    var updatedAt: Date
    var revision: Int
    /// Period the summary covers, used for date filtering.
    var periodStart: Date
    var periodEnd: Date

    var confidence: Double
    var assertionRaw: String
    var sourceKindRaw: String
    var sourceIDs: [String]
    /// `foundationModels` or `extractive` — the user can see which produced this.
    var generator: String

    @Attribute(.externalStorage) var embedding: Data?

    init(id: UUID = UUID(),
         scope: SummaryScope,
         key: String,
         title: String,
         text: String,
         bullets: [String] = [],
         createdAt: Date = Date(),
         revision: Int = 1,
         periodStart: Date = Date(),
         periodEnd: Date = Date(),
         confidence: Double = 0.5,
         assertion: AssertionKind = .summarised,
         sourceKind: SourceKind = .transcriptSegment,
         sourceIDs: [String] = [],
         generator: String = "extractive",
         embedding: Data? = nil) {
        self.id = id
        self.scopeRaw = scope.rawValue
        self.key = key
        self.title = title
        self.text = text
        self.bulletsData = bullets.isEmpty ? nil : try? JSONEncoder().encode(bullets)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.revision = revision
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.confidence = confidence
        self.assertionRaw = assertion.rawValue
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceIDs = sourceIDs
        self.generator = generator
        self.embedding = embedding
    }

    var scope: SummaryScope {
        get { SummaryScope(rawValue: scopeRaw) ?? .conversation }
        set { scopeRaw = newValue.rawValue }
    }

    var assertion: AssertionKind {
        get { AssertionKind(rawValue: assertionRaw) ?? .summarised }
        set { assertionRaw = newValue.rawValue }
    }

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .transcriptSegment }
        set { sourceKindRaw = newValue.rawValue }
    }

    var bullets: [String] {
        get {
            guard let bulletsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: bulletsData)) ?? []
        }
        set {
            bulletsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}

/// Two memories that cannot both be right.
///
/// Recorded rather than resolved: Clipper has no way to know which statement is true, so it
/// keeps both, marks both `.contradictory`, and shows the user the pair with the evidence
/// for each. Resolution is a user action.
@Model
final class ContradictionRecord {
    #Index<ContradictionRecord>([\.detectedAt], [\.isResolved])

    @Attribute(.unique) var id: UUID
    var earlierMemoryID: UUID
    var laterMemoryID: UUID
    /// Plain-language statement of the conflict, built from both titles.
    var explanation: String
    var detectedAt: Date
    var confidence: Double
    var isResolved: Bool
    var resolvedAt: Date?
    /// Which memory the user kept, if they resolved it.
    var keptMemoryID: UUID?

    init(id: UUID = UUID(),
         earlierMemoryID: UUID,
         laterMemoryID: UUID,
         explanation: String,
         detectedAt: Date = Date(),
         confidence: Double = 0.5) {
        self.id = id
        self.earlierMemoryID = earlierMemoryID
        self.laterMemoryID = laterMemoryID
        self.explanation = explanation
        self.detectedAt = detectedAt
        self.confidence = confidence
        self.isResolved = false
        self.resolvedAt = nil
        self.keptMemoryID = nil
    }
}
