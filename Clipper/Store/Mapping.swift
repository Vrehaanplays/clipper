import Foundation

// Model → DTO. Called from whichever context owns the model; the result is a value type,
// so it is safe to send anywhere.

extension Array where Element == String {
    /// Parse a stored list of UUID strings, dropping anything unparseable rather than
    /// crashing on one bad row.
    var asUUIDs: [UUID] { compactMap(UUID.init(uuidString:)) }
}

extension Array where Element == UUID {
    var asStrings: [String] { map(\.uuidString) }
}

extension SessionRecord {
    var dto: SessionDTO {
        SessionDTO(id: id,
                   startedAt: startedAt,
                   endedAt: endedAt,
                   speechSeconds: speechSeconds,
                   utteranceCount: utteranceCount,
                   interruptionCount: interruptionCount,
                   inputName: inputName,
                   usedBuiltInMic: usedBuiltInMic)
    }
}

extension SpeakerRecord {
    var dto: SpeakerDTO {
        SpeakerDTO(id: id,
                   displayName: displayName,
                   isNamed: isNamed,
                   sampleCount: sampleCount,
                   totalSpeechSeconds: totalSpeechSeconds,
                   identityConfidence: identityConfidence,
                   promptState: promptState,
                   colorIndex: colorIndex,
                   createdAt: createdAt,
                   previousNames: previousNames)
    }
}

extension MemoryRecord {
    var dto: MemoryDTO {
        MemoryDTO(id: id,
                  kind: kind,
                  title: title,
                  detail: detail,
                  confidence: confidence,
                  assertion: assertion,
                  importance: importance,
                  createdAt: createdAt,
                  updatedAt: updatedAt,
                  firstSeenAt: firstSeenAt,
                  lastSeenAt: lastSeenAt,
                  occurrenceCount: occurrenceCount,
                  revision: revision,
                  supersedesID: supersedesID,
                  supersededByID: supersededByID,
                  isArchived: isArchived,
                  isUserEdited: isUserEdited,
                  sourceKind: sourceKind,
                  sourceIDs: sourceIDs.asUUIDs,
                  nodeIDs: nodeIDs.asUUIDs,
                  subjectSpeakerID: subjectSpeakerID,
                  strength: strength)
    }
}

extension SummaryRecord {
    var dto: SummaryDTO {
        SummaryDTO(id: id,
                   scope: scope,
                   key: key,
                   title: title,
                   text: text,
                   bullets: bullets,
                   createdAt: createdAt,
                   updatedAt: updatedAt,
                   revision: revision,
                   periodStart: periodStart,
                   periodEnd: periodEnd,
                   confidence: confidence,
                   assertion: assertion,
                   sourceKind: sourceKind,
                   sourceIDs: sourceIDs.asUUIDs,
                   generator: generator)
    }
}

extension GraphNodeRecord {
    var dto: GraphNodeDTO {
        GraphNodeDTO(id: id,
                     kind: kind,
                     name: name,
                     mentionCount: mentionCount,
                     importance: importance,
                     lastMentionedAt: lastMentionedAt,
                     refID: refID,
                     summaryID: summaryID)
    }
}

extension GraphEdgeRecord {
    var dto: GraphEdgeDTO {
        GraphEdgeDTO(id: id,
                     sourceNodeID: sourceNodeID,
                     targetNodeID: targetNodeID,
                     kind: kind,
                     weight: weight,
                     confidence: confidence,
                     evidenceIDs: evidenceIDs.asUUIDs,
                     evidenceKind: evidenceKind)
    }
}

extension ConversationRecord {
    func dto(summaryText: String? = nil,
             summaryIdentifier: UUID? = nil,
             speakerLabels: [String] = [],
             topicNames: [String] = []) -> ConversationDTO {
        ConversationDTO(id: id,
                        sessionID: sessionID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        title: title,
                        segmentCount: segmentCount,
                        speechSeconds: speechSeconds,
                        confidence: confidence,
                        importance: importance,
                        isOpen: isOpen,
                        speakerLabels: speakerLabels,
                        summaryText: summaryText,
                        summaryID: summaryIdentifier ?? summaryID,
                        topicNames: topicNames,
                        nodeIDs: nodeIDs.asUUIDs,
                        speakerIDs: speakerIDs.asUUIDs)
    }
}

extension TranscriptSegmentRecord {
    func dto(speakerLabel: String = "Unknown voice",
             speakerColorIndex: Int = 0,
             audioAvailable: Bool = false) -> TranscriptLineDTO {
        TranscriptLineDTO(id: id,
                          sessionID: sessionID,
                          conversationID: conversationID,
                          speakerID: speakerID,
                          speakerLabel: speakerLabel,
                          speakerColorIndex: speakerColorIndex,
                          startedAt: startedAt,
                          endedAt: endedAt,
                          text: text,
                          confidence: confidence,
                          speakerConfidence: speakerConfidence,
                          audioQuality: audioQuality,
                          assertion: assertion,
                          processingState: processingState,
                          isLowConfidence: isLowConfidence,
                          audioSegmentID: audioSegmentID,
                          audioAvailable: audioAvailable,
                          wordTimings: wordTimings,
                          wasEdited: originalText != nil)
    }
}
