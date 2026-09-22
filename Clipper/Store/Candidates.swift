import Foundation

// Inputs to the store. Value types, built by the pipeline, consumed by `ClipperStore`.
// Keeping them separate from the `@Model` classes is what lets the pipeline run its
// analysis without holding a `ModelContext` open.

/// One thing the extractor found in one transcript segment.
struct ExtractionCandidate: Hashable, Sendable {
    var kind: MemoryKind
    var text: String
    var subject: String?
    var confidence: Double
    var assertion: AssertionKind

    init(kind: MemoryKind,
         text: String,
         subject: String? = nil,
         confidence: Double = 0.5,
         assertion: AssertionKind = .stated) {
        self.kind = kind
        self.text = text
        self.subject = subject
        self.confidence = confidence
        self.assertion = assertion
    }
}

/// A named thing found in speech, ready to become a brain-map node.
struct EntityCandidate: Hashable, Sendable {
    var name: String
    var kind: NodeKind
    var confidence: Double
}

/// A memory to create or reinforce. `dedupeKey` is what makes this an upsert: the same key
/// twice reinforces one row instead of writing two.
struct MemoryCandidate: Hashable, Sendable {
    var kind: MemoryKind
    var title: String
    var detail: String
    var confidence: Double
    var assertion: AssertionKind
    var importance: Double
    var occurredAt: Date
    var sourceKind: SourceKind
    var sourceIDs: [UUID]
    var nodeIDs: [UUID]
    var subjectSpeakerID: UUID?
    var dedupeKey: String
    var embedding: [Float]
    /// How many separate sightings this candidate was built from. A statement made three
    /// times in one conversation is one memory that was heard three times, and the count
    /// is what the evidence view and the importance weighting read.
    var occurrences: Int
    /// When true, a materially different detail for the same key supersedes the old
    /// memory instead of merging into it — which is how a changed decision keeps its
    /// history.
    var supersedeOnChange: Bool

    init(kind: MemoryKind,
         title: String,
         detail: String = "",
         confidence: Double = 0.5,
         assertion: AssertionKind = .summarised,
         importance: Double = 0.3,
         occurredAt: Date = Date(),
         sourceKind: SourceKind = .transcriptSegment,
         sourceIDs: [UUID] = [],
         nodeIDs: [UUID] = [],
         subjectSpeakerID: UUID? = nil,
         dedupeKey: String,
         occurrences: Int = 1,
         embedding: [Float] = [],
         supersedeOnChange: Bool = false) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.confidence = confidence
        self.assertion = assertion
        self.importance = importance
        self.occurredAt = occurredAt
        self.sourceKind = sourceKind
        self.sourceIDs = sourceIDs
        self.nodeIDs = nodeIDs
        self.subjectSpeakerID = subjectSpeakerID
        self.dedupeKey = dedupeKey
        self.occurrences = max(1, occurrences)
        self.embedding = embedding
        self.supersedeOnChange = supersedeOnChange
    }
}

/// A document to add to or refresh in the search index.
struct IndexCandidate: Hashable, Sendable {
    var kind: DocumentKind
    var refID: UUID
    var conversationID: UUID?
    var title: String
    var text: String
    var timestamp: Date
    var speakerIDs: [UUID]
    var nodeIDs: [UUID]
    var importance: Double
    var confidence: Double
    var assertion: AssertionKind
    var embedding: [Float]
}

/// A result of speaker attribution, including how much to trust it.
struct SpeakerMatch: Hashable, Sendable {
    var speakerID: UUID
    var confidence: Double
    var isNewCluster: Bool
    var sampleCount: Int
}

/// What a summariser produced, before it is stored.
struct SummaryDraft: Hashable, Sendable {
    var title: String
    var text: String
    var bullets: [String]
    var confidence: Double
    /// `foundationModels` or `extractive`.
    var generator: String
}
