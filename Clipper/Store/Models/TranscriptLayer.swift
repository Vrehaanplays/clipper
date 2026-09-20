import Foundation
import SwiftData

/// Where Clipper is in the process of asking the user who a voice belongs to.
enum SpeakerPromptState: String, Codable, CaseIterable, Sendable {
    /// Enough audio collected to be worth asking about, but not asked yet.
    case pending
    /// Asked, and the user said "later".
    case askLater
    /// Asked, and the user said "skip" — never ask about this voice again.
    case skipped
    /// Named by the user.
    case named
}

/// One voice. Not "one person" — Clipper cannot know that, and the distinction is kept
/// visible throughout the UI.
///
/// Attribution is log-mel centroid clustering, which is a genuine technique and a weak one.
/// `confidence` on every `TranscriptSegmentRecord` records how close the match was, and an
/// unnamed speaker is always shown as unknown rather than as a guess.
@Model
final class SpeakerRecord {
    #Index<SpeakerRecord>([\.createdAt], [\.displayName])

    @Attribute(.unique) var id: UUID
    /// `nil` until the user names this voice.
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date

    /// Running mean of the voice's feature vector, as float32 bytes.
    @Attribute(.externalStorage) var embedding: Data
    /// How many utterances contributed to the centroid. More samples, more trust.
    var sampleCount: Int
    var totalSpeechSeconds: Double

    var promptStateRaw: String
    /// Stable colour slot so the same voice looks the same everywhere.
    var colorIndex: Int
    /// Set when the user renames or merges — the old label is kept rather than overwritten.
    var previousNames: [String]

    init(id: UUID = UUID(),
         displayName: String? = nil,
         createdAt: Date = Date(),
         embedding: Data = Data(),
         sampleCount: Int = 0,
         totalSpeechSeconds: Double = 0,
         promptState: SpeakerPromptState = .pending,
         colorIndex: Int = 0,
         previousNames: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.embedding = embedding
        self.sampleCount = sampleCount
        self.totalSpeechSeconds = totalSpeechSeconds
        self.promptStateRaw = promptState.rawValue
        self.colorIndex = colorIndex
        self.previousNames = previousNames
    }

    var promptState: SpeakerPromptState {
        get { SpeakerPromptState(rawValue: promptStateRaw) ?? .pending }
        set { promptStateRaw = newValue.rawValue }
    }

    var isNamed: Bool { displayName?.isEmpty == false }

    var label: String { displayName ?? "Unknown voice" }

    /// How much to trust this cluster as an identity at all.
    var identityConfidence: Double {
        guard sampleCount > 0 else { return 0 }
        let bySamples = min(1, Double(sampleCount) / 8)
        return isNamed ? max(0.6, bySamples) : bySamples * 0.6
    }
}

/// One stretch of transcribed speech. The atom of the transcript layer, and the leaf every
/// evidence chain ends at.
///
/// Carries every field the spec requires: stable id, session, conversation, start and end,
/// speaker or unknown, text, confidence, audio reference, processing state, provenance.
@Model
final class TranscriptSegmentRecord {
    #Index<TranscriptSegmentRecord>([\.startedAt], [\.sessionID], [\.conversationID], [\.processingStateRaw])

    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    /// Assigned when the segmenter decides which conversation this belongs to.
    var conversationID: UUID?
    /// The evidence audio this text came from, if it was retained.
    var audioSegmentID: UUID?
    /// `nil` means the voice was never clustered — genuinely unknown, not "probably me".
    var speakerID: UUID?

    var startedAt: Date
    var endedAt: Date
    var index: Int

    var text: String
    /// Mean recogniser confidence, 0...1.
    var confidence: Double
    /// How good the underlying audio was.
    var audioQuality: Double
    /// Closeness of the speaker match, 0...1. Low values render as uncertain.
    var speakerConfidence: Double

    var assertionRaw: String
    var processingStateRaw: String
    var createdAt: Date
    var revision: Int

    /// Per-word or per-phrase timings, as JSON. Kept out of its own table because it is
    /// only ever read alongside the segment, and a table would double the row count.
    @Attribute(.externalStorage) var wordTimingsData: Data?

    var languageCode: String?
    /// True when the recogniser or the audio metrics said this is weak.
    var isLowConfidence: Bool
    /// Set if the user edited the text. Original text is preserved in `originalText`.
    var originalText: String?

    init(id: UUID = UUID(),
         sessionID: UUID,
         conversationID: UUID? = nil,
         audioSegmentID: UUID? = nil,
         speakerID: UUID? = nil,
         startedAt: Date,
         endedAt: Date,
         index: Int = 0,
         text: String = "",
         confidence: Double = 0,
         audioQuality: Double = 0,
         speakerConfidence: Double = 0,
         assertion: AssertionKind = .stated,
         processingState: ProcessingState = .pending,
         createdAt: Date = Date(),
         revision: Int = 1,
         wordTimingsData: Data? = nil,
         languageCode: String? = nil,
         isLowConfidence: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.audioSegmentID = audioSegmentID
        self.speakerID = speakerID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.index = index
        self.text = text
        self.confidence = confidence
        self.audioQuality = audioQuality
        self.speakerConfidence = speakerConfidence
        self.assertionRaw = assertion.rawValue
        self.processingStateRaw = processingState.rawValue
        self.createdAt = createdAt
        self.revision = revision
        self.wordTimingsData = wordTimingsData
        self.languageCode = languageCode
        self.isLowConfidence = isLowConfidence
        self.originalText = nil
    }

    var assertion: AssertionKind {
        get { AssertionKind(rawValue: assertionRaw) ?? .stated }
        set { assertionRaw = newValue.rawValue }
    }

    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .pending }
        set { processingStateRaw = newValue.rawValue }
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var wordTimings: [WordTiming] {
        get {
            guard let wordTimingsData else { return [] }
            return (try? JSONDecoder().decode([WordTiming].self, from: wordTimingsData)) ?? []
        }
        set {
            wordTimingsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}

/// One word or phrase with its offset inside the utterance.
struct WordTiming: Codable, Hashable, Sendable {
    var text: String
    /// Seconds from the start of the utterance.
    var offset: TimeInterval
    var duration: TimeInterval
    var confidence: Double
}

/// A run of transcript segments that belong together.
///
/// Boundaries come from `ConversationSegmenter`: a long enough silence, a change in who is
/// speaking, or a topic shift. Conversations are the unit that gets summarised, so getting
/// this wrong shows up directly in the quality of everything above it.
@Model
final class ConversationRecord {
    #Index<ConversationRecord>([\.startedAt], [\.sessionID], [\.isOpen])

    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var startedAt: Date
    var endedAt: Date

    var title: String
    /// Set once a summary has been generated.
    var summaryID: UUID?

    var segmentCount: Int
    var speechSeconds: Double
    /// Mean transcription confidence across the segments.
    var confidence: Double
    /// 0...1, from length, speaker count, and how much extracted content it produced.
    var importance: Double

    /// Still accepting segments. Closed conversations are the ones that get summarised.
    var isOpen: Bool
    var closedAt: Date?

    /// UUID strings. SwiftData relationships were deliberately not used — see
    /// docs/ARCHITECTURE.md.
    var speakerIDs: [String]
    var nodeIDs: [String]

    init(id: UUID = UUID(),
         sessionID: UUID,
         startedAt: Date,
         endedAt: Date,
         title: String = "Conversation",
         summaryID: UUID? = nil,
         segmentCount: Int = 0,
         speechSeconds: Double = 0,
         confidence: Double = 0,
         importance: Double = 0,
         isOpen: Bool = true,
         speakerIDs: [String] = [],
         nodeIDs: [String] = []) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.summaryID = summaryID
        self.segmentCount = segmentCount
        self.speechSeconds = speechSeconds
        self.confidence = confidence
        self.importance = importance
        self.isOpen = isOpen
        self.closedAt = nil
        self.speakerIDs = speakerIDs
        self.nodeIDs = nodeIDs
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// One thing the extractor found inside one transcript segment: a question, a decision, a
/// named entity, a claim.
///
/// Extractions are cheap, numerous and always traceable to exactly one segment. Memories
/// are built from them by aggregation, which is what keeps the curated layer small.
@Model
final class ExtractionRecord {
    #Index<ExtractionRecord>([\.createdAt], [\.conversationID], [\.transcriptSegmentID], [\.kindRaw])

    @Attribute(.unique) var id: UUID
    var transcriptSegmentID: UUID
    var conversationID: UUID?
    var speakerID: UUID?

    var kindRaw: String
    /// The extracted text, normally one sentence, verbatim from the transcript.
    var text: String
    /// For entity extractions: the entity name. For others, `nil`.
    var subject: String?
    var confidence: Double
    var assertionRaw: String
    var createdAt: Date
    var occurredAt: Date

    init(id: UUID = UUID(),
         transcriptSegmentID: UUID,
         conversationID: UUID? = nil,
         speakerID: UUID? = nil,
         kind: MemoryKind,
         text: String,
         subject: String? = nil,
         confidence: Double = 0.5,
         assertion: AssertionKind = .stated,
         createdAt: Date = Date(),
         occurredAt: Date = Date()) {
        self.id = id
        self.transcriptSegmentID = transcriptSegmentID
        self.conversationID = conversationID
        self.speakerID = speakerID
        self.kindRaw = kind.rawValue
        self.text = text
        self.subject = subject
        self.confidence = confidence
        self.assertionRaw = assertion.rawValue
        self.createdAt = createdAt
        self.occurredAt = occurredAt
    }

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .claim }
        set { kindRaw = newValue.rawValue }
    }

    var assertion: AssertionKind {
        get { AssertionKind(rawValue: assertionRaw) ?? .stated }
        set { assertionRaw = newValue.rawValue }
    }
}
