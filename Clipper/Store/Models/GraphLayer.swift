import Foundation
import SwiftData

/// A node in the brain map.
///
/// Nodes are created by the extractor (people, topics, places, projects, events, concepts)
/// and by the memory builder (memories, summaries, conversations). `refID` points back at
/// the record a node stands for, so a node is never a second copy of the data — it is an
/// index into it.
///
/// `normalizedName` is the dedupe key: "the Aurora project", "Aurora Project" and "aurora
/// project" are one node.
@Model
final class GraphNodeRecord {
    #Index<GraphNodeRecord>([\.normalizedName], [\.kindRaw], [\.lastMentionedAt], [\.mentionCount])

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var name: String
    var normalizedName: String

    var createdAt: Date
    var updatedAt: Date
    var lastMentionedAt: Date
    var mentionCount: Int
    /// 0...1. Drives which nodes a focused subgraph shows first.
    var importance: Double

    /// The record this node stands for, when it stands for one.
    var refID: UUID?
    var refKindRaw: String?
    /// Latest topic/project summary for this node, if one has been generated.
    var summaryID: UUID?

    @Attribute(.externalStorage) var embedding: Data?

    init(id: UUID = UUID(),
         kind: NodeKind,
         name: String,
         normalizedName: String,
         createdAt: Date = Date(),
         lastMentionedAt: Date = Date(),
         mentionCount: Int = 1,
         importance: Double = 0.1,
         refID: UUID? = nil,
         refKind: SourceKind? = nil,
         summaryID: UUID? = nil,
         embedding: Data? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.normalizedName = normalizedName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.lastMentionedAt = lastMentionedAt
        self.mentionCount = mentionCount
        self.importance = importance
        self.refID = refID
        self.refKindRaw = refKind?.rawValue
        self.summaryID = summaryID
        self.embedding = embedding
    }

    var kind: NodeKind {
        get { NodeKind(rawValue: kindRaw) ?? .concept }
        set { kindRaw = newValue.rawValue }
    }

    var refKind: SourceKind? {
        get { refKindRaw.flatMap(SourceKind.init(rawValue:)) }
        set { refKindRaw = newValue?.rawValue }
    }
}

/// A relationship between two nodes, with the evidence that created it.
///
/// `evidenceIDs` is not decoration: the brain map lets the user tap an edge and read the
/// transcript segments that produced it. An edge with no evidence is a bug, and
/// `isExplainable` is what the UI checks before offering the tap.
@Model
final class GraphEdgeRecord {
    #Index<GraphEdgeRecord>([\.sourceNodeID], [\.targetNodeID], [\.kindRaw], [\.weight])

    @Attribute(.unique) var id: UUID
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var kindRaw: String

    /// Accumulated co-occurrence strength. Used to prune the graph for display.
    var weight: Double
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date

    var evidenceIDs: [String]
    var evidenceKindRaw: String

    init(id: UUID = UUID(),
         sourceNodeID: UUID,
         targetNodeID: UUID,
         kind: EdgeKind,
         weight: Double = 1,
         confidence: Double = 0.5,
         createdAt: Date = Date(),
         evidenceIDs: [String] = [],
         evidenceKind: SourceKind = .transcriptSegment) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.kindRaw = kind.rawValue
        self.weight = weight
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.evidenceIDs = evidenceIDs
        self.evidenceKindRaw = evidenceKind.rawValue
    }

    var kind: EdgeKind {
        get { EdgeKind(rawValue: kindRaw) ?? .relatedTo }
        set { kindRaw = newValue.rawValue }
    }

    var evidenceKind: SourceKind {
        get { SourceKind(rawValue: evidenceKindRaw) ?? .transcriptSegment }
        set { evidenceKindRaw = newValue.rawValue }
    }

    var isExplainable: Bool { !evidenceIDs.isEmpty }
}
