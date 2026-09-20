import Foundation
import SwiftData

/// One searchable thing, denormalised for search.
///
/// Search reads only this table plus the postings, never the transcript or memory tables.
/// That is deliberate: it keeps the hot path to two indexed fetches regardless of how much
/// history has accumulated, and it means adding a filter never means widening a join.
@Model
final class IndexedDocumentRecord {
    #Index<IndexedDocumentRecord>([\.timestamp], [\.kindRaw], [\.refID], [\.importance])

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    /// The record this document represents.
    var refID: UUID
    var conversationID: UUID?

    var title: String
    /// The searchable body, as written.
    var text: String
    var timestamp: Date
    var indexedAt: Date

    var speakerIDs: [String]
    var nodeIDs: [String]

    var importance: Double
    var confidence: Double
    var assertionRaw: String
    /// Total tokens, needed for length normalisation in the ranking function.
    var tokenCount: Int

    @Attribute(.externalStorage) var embedding: Data?

    init(id: UUID = UUID(),
         kind: DocumentKind,
         refID: UUID,
         conversationID: UUID? = nil,
         title: String,
         text: String,
         timestamp: Date,
         speakerIDs: [String] = [],
         nodeIDs: [String] = [],
         importance: Double = 0.2,
         confidence: Double = 0.5,
         assertion: AssertionKind = .stated,
         tokenCount: Int = 0,
         embedding: Data? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.refID = refID
        self.conversationID = conversationID
        self.title = title
        self.text = text
        self.timestamp = timestamp
        self.indexedAt = Date()
        self.speakerIDs = speakerIDs
        self.nodeIDs = nodeIDs
        self.importance = importance
        self.confidence = confidence
        self.assertionRaw = assertion.rawValue
        self.tokenCount = tokenCount
        self.embedding = embedding
    }

    var kind: DocumentKind {
        get { DocumentKind(rawValue: kindRaw) ?? .transcriptSegment }
        set { kindRaw = newValue.rawValue }
    }

    var assertion: AssertionKind {
        get { AssertionKind(rawValue: assertionRaw) ?? .stated }
        set { assertionRaw = newValue.rawValue }
    }

    var deepLink: ClipperDeepLink {
        switch kind {
        case .transcriptSegment, .conversation:
            return .conversation(conversationID ?? refID)
        case .summary, .memory:
            return .memory(refID)
        case .speaker:
            return .speaker(refID)
        case .node:
            return .node(refID)
        }
    }
}

/// One token in one document: the inverted index.
///
/// This is the table that replaces SQLite FTS5. It is the largest table in the store by
/// row count — roughly 35 unique tokens per document — and it is indexed on `token`, so a
/// term lookup is a B-tree seek rather than a scan of the transcript. Growth estimates are
/// in docs/PERFORMANCE.md.
@Model
final class TokenPostingRecord {
    #Index<TokenPostingRecord>([\.token], [\.documentID])

    @Attribute(.unique) var id: UUID
    /// Lowercased, diacritic-folded, stemmed-lite token.
    var token: String
    var documentID: UUID
    /// Term frequency in this document, already length-normalised.
    var weight: Double
    /// Denormalised so a term lookup can date-filter without loading the document.
    var timestamp: Date

    init(id: UUID = UUID(),
         token: String,
         documentID: UUID,
         weight: Double,
         timestamp: Date) {
        self.id = id
        self.token = token
        self.documentID = documentID
        self.weight = weight
        self.timestamp = timestamp
    }
}

/// A unit of deferred work.
///
/// Jobs are persisted rather than held in memory so that being killed mid-pipeline loses
/// nothing: on the next launch, `pending` and stranded `running` jobs are picked up where
/// they stopped. `attempts` caps the retries so a permanently broken item cannot spin.
@Model
final class JobRecord {
    #Index<JobRecord>([\.stateRaw], [\.createdAt], [\.kindRaw], [\.priority])

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var stateRaw: String
    /// Small JSON payload — ids and file names, never audio or text bodies.
    var payload: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var attempts: Int
    var lastError: String?
    /// Higher runs first. Live utterances outrank nightly rollups.
    var priority: Int

    init(id: UUID = UUID(),
         kind: JobKind,
         state: JobState = .pending,
         payload: String = "{}",
         createdAt: Date = Date(),
         priority: Int = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.stateRaw = state.rawValue
        self.payload = payload
        self.createdAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
        self.attempts = 0
        self.lastError = nil
        self.priority = priority
    }

    var kind: JobKind {
        get { JobKind(rawValue: kindRaw) ?? .processUtterance }
        set { kindRaw = newValue.rawValue }
    }

    var state: JobState {
        get { JobState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    static let maxAttempts = 3
}

/// One row, holding the store's own version and health notes.
///
/// The migration strategy leans on this rather than on SwiftData's automatic inference
/// alone: `version` records which shape the data was written in, so a future migration can
/// tell whether it needs to run at all, and `recoveredAt` records that the store was once
/// rebuilt after corruption.
@Model
final class StoreMetaRecord {
    @Attribute(.unique) var id: UUID
    var version: Int
    var createdAt: Date
    var lastOpenedAt: Date
    var openCount: Int
    var recoveredAt: Date?
    var notes: String?

    init(id: UUID = UUID(),
         version: Int,
         createdAt: Date = Date()) {
        self.id = id
        self.version = version
        self.createdAt = createdAt
        self.lastOpenedAt = createdAt
        self.openCount = 1
        self.recoveredAt = nil
        self.notes = nil
    }
}
