import Foundation
import SwiftData
import XCTest

@testable import Clipper

/// Everything the database promises: identity, grouping, supersession, idempotency and the
/// job queue. Every test builds its own in-memory container, so they can run in any order
/// and none of them can see another's rows.
final class StoreSchemaTests: XCTestCase {

    func testInMemoryContainerOpensWithTheVersionedSchema() throws {
        let container = try ClipperDatabase.inMemory()
        XCTAssertFalse(container.schema.entities.isEmpty)

        // Every model the app persists must be reachable from the schema, or a fetch for it
        // traps at runtime rather than failing a test.
        let names = Set(container.schema.entities.map(\.name))
        for expected in ["SessionRecord", "AudioSegmentRecord", "SpeakerRecord",
                         "TranscriptSegmentRecord", "ConversationRecord", "ExtractionRecord",
                         "MemoryRecord", "SummaryRecord", "ContradictionRecord",
                         "GraphNodeRecord", "GraphEdgeRecord", "IndexedDocumentRecord",
                         "TokenPostingRecord", "JobRecord", "StoreMetaRecord"] {
            XCTAssertTrue(names.contains(expected), "\(expected) is missing from the schema")
        }
    }

    /// The migration plan must name V1 as a stage, otherwise a future V2 has nothing to
    /// migrate from.
    func testMigrationPlanDeclaresTheCurrentSchema() {
        XCTAssertTrue(ClipperMigrationPlan.schemas.contains { $0 == ClipperSchemaV1.self })
        XCTAssertEqual(ClipperSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func testEmptyStoreReportsZeroes() async throws {
        let store = try TestStore.make()
        let stats = await store.stats()
        XCTAssertEqual(stats.sessions, 0)
        XCTAssertEqual(stats.memories, 0)
        XCTAssertEqual(stats.pendingJobs, 0)
    }
}

// MARK: - Sessions and raw audio

final class SessionStoreTests: XCTestCase {

    func testSessionLifecycleAccumulatesSpeech() async throws {
        let store = try TestStore.make()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        await store.startSession(id: id,
                                 at: start,
                                 inputName: "iPhone Microphone",
                                 usedBuiltInMic: true,
                                 otherAudioPlaying: true)

        await store.noteUtterance(sessionID: id, seconds: 3.5)
        await store.noteUtterance(sessionID: id, seconds: 2.5)
        await store.noteInterruption(sessionID: id)
        await store.endSession(id: id, at: start.addingTimeInterval(120))

        let session = try XCTUnwrap(await store.sessions().first)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.speechSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(session.utteranceCount, 2)
        XCTAssertEqual(session.interruptionCount, 1)
        XCTAssertFalse(session.isOpen)
        XCTAssertTrue(session.usedBuiltInMic)
        XCTAssertEqual(session.duration, 120, accuracy: 0.001)
    }

    /// The app can be killed mid-session. On the next launch those rows must be closed,
    /// otherwise the timeline shows a session that has been "recording" for a week.
    func testStrandedSessionsAreClosedOnBootstrap() async throws {
        let store = try TestStore.make()
        for _ in 0..<3 {
            await store.startSession(id: UUID(),
                                     at: Date().addingTimeInterval(-3_600),
                                     inputName: nil,
                                     usedBuiltInMic: true,
                                     otherAudioPlaying: false)
        }
        let closed = await store.closeStrandedSessions()
        XCTAssertEqual(closed, 3)
        let stillOpen = await store.sessions().filter(\.isOpen)
        XCTAssertTrue(stillOpen.isEmpty)
        // Idempotent: a second bootstrap has nothing left to do.
        let again = await store.closeStrandedSessions()
        XCTAssertEqual(again, 0)
    }

    /// Rolling clips are a *reference* to a file the buffer owns. When the buffer deletes
    /// the file, the row must go too.
    func testRollingClipsAreReconciledAgainstTheFilesystem() async throws {
        let store = try TestStore.make()
        let sessionID = UUID()
        await store.startSession(id: sessionID, at: Date(), inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)

        for index in 0..<4 {
            await store.recordRollingClip(sessionID: sessionID,
                                          filename: "clip-\(index).m4a",
                                          startedAt: Date().addingTimeInterval(Double(index) * 30),
                                          duration: 30,
                                          byteSize: 10_000,
                                          sampleRate: 48_000)
        }
        var stats = await store.stats()
        XCTAssertEqual(stats.audioSegments, 4)

        await store.reconcileRollingClips(existing: ["clip-2.m4a", "clip-3.m4a"])
        stats = await store.stats()
        XCTAssertEqual(stats.audioSegments, 2, "Rows for deleted files must not survive")
    }

    /// Evidence is a different lifecycle: the row outlives the audio, and says so.
    func testEvidenceSegmentSurvivesItsAudioAndSaysSo() async throws {
        let store = try TestStore.make()
        let sessionID = UUID()
        let segmentID = UUID()
        let start = Date()
        await store.startSession(id: sessionID, at: start, inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)
        await store.createEvidenceSegment(id: segmentID,
                                          sessionID: sessionID,
                                          filename: "utterance.wav",
                                          startedAt: start,
                                          endedAt: start.addingTimeInterval(4),
                                          sampleRate: 16_000,
                                          byteSize: 128_000,
                                          meanSNRDB: 14,
                                          peakLevelDB: -12,
                                          noiseFloorDB: -46,
                                          speechRatio: 0.8)

        XCTAssertTrue(await store.evidenceAudioAvailable(segmentID))
        XCTAssertGreaterThan(await store.segmentQuality(id: segmentID), 0)

        await store.markEvidenceExpired(ids: [segmentID])
        XCTAssertFalse(await store.evidenceAudioAvailable(segmentID),
                       "Expired audio must be reported as gone, not silently linked")

        let stats = await store.stats()
        XCTAssertEqual(stats.audioSegments, 1, "The row itself stays, for provenance")
    }

    func testDaysWithActivityAreDistinctAndDescending() async throws {
        let store = try TestStore.make()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        for offset in [0.0, 3_600.0, 86_400.0 * 2] {
            let id = UUID()
            await store.startSession(id: id, at: day.addingTimeInterval(offset), inputName: nil,
                                     usedBuiltInMic: true, otherAudioPlaying: false)
            await store.endSession(id: id, at: day.addingTimeInterval(offset + 60))
        }
        let days = await store.daysWithActivity()
        XCTAssertEqual(days.count, 2, "Two sessions on the same day are one day")
        XCTAssertGreaterThan(days[0], days[1], "Newest first")
    }
}

// MARK: - Speakers

final class SpeakerStoreTests: XCTestCase {

    /// The first voice creates a cluster; the same voice again joins it; a different voice
    /// starts its own.
    func testAttributionClustersVoicesAndSplitsStrangers() async throws {
        let store = try TestStore.make()
        let alex = MessyCorpus.signature(for: "Alex")
        let sam = MessyCorpus.signature(for: "Sam")

        let first = try XCTUnwrap(await store.attributeSpeaker(embedding: alex, seconds: 5))
        XCTAssertTrue(first.isNewCluster)
        XCTAssertEqual(first.sampleCount, 1)

        // Slightly perturbed — the same person never produces a bit-identical vector.
        let nudged = VectorMath.normalized(alex.enumerated().map { index, value in
            value + (index.isMultiple(of: 7) ? 0.01 : -0.005)
        })
        let second = try XCTUnwrap(await store.attributeSpeaker(embedding: nudged, seconds: 5))
        XCTAssertFalse(second.isNewCluster)
        XCTAssertEqual(second.speakerID, first.speakerID)
        XCTAssertEqual(second.sampleCount, 2)

        let other = try XCTUnwrap(await store.attributeSpeaker(embedding: sam, seconds: 5))
        XCTAssertTrue(other.isNewCluster)
        XCTAssertNotEqual(other.speakerID, first.speakerID)

        XCTAssertEqual(await store.speakers().count, 2)
    }

    func testEmptyEmbeddingProducesNoAttributionRatherThanAGuess() async throws {
        let store = try TestStore.make()
        let match = await store.attributeSpeaker(embedding: [], seconds: 5)
        XCTAssertNil(match, "No features means unknown, not a made-up cluster")
        XCTAssertTrue(await store.speakers().isEmpty)
    }

    func testUnnamedSpeakerRendersAsUnknownVoice() async throws {
        let store = try TestStore.make()
        let match = try XCTUnwrap(await store.attributeSpeaker(embedding: MessyCorpus.signature(for: "X"),
                                                               seconds: 5))
        let speaker = try XCTUnwrap(await store.speaker(id: match.speakerID))
        XCTAssertFalse(speaker.isNamed)
        XCTAssertEqual(speaker.label, "Unknown voice")
    }

    /// The naming prompt must not fire for a voice we heard once in passing.
    func testNamingPromptsWaitForEnoughEvidence() async throws {
        let store = try TestStore.make()
        let vector = MessyCorpus.signature(for: "Alex")
        _ = await store.attributeSpeaker(embedding: vector, seconds: 3)
        XCTAssertTrue(await store.speakersAwaitingNames().isEmpty,
                      "One short sample is not enough to interrupt the user")

        for _ in 0..<4 { _ = await store.attributeSpeaker(embedding: vector, seconds: 6) }
        XCTAssertEqual(await store.speakersAwaitingNames().count, 1)
    }

    func testSkipSuppressesThePromptAndAskLaterRaisesTheBar() async throws {
        let store = try TestStore.make()
        let vector = MessyCorpus.signature(for: "Alex")
        var speakerID = UUID()
        for _ in 0..<5 {
            let match = try XCTUnwrap(await store.attributeSpeaker(embedding: vector, seconds: 6))
            speakerID = match.speakerID
        }
        XCTAssertEqual(await store.speakersAwaitingNames().count, 1)

        await store.setSpeakerPromptState(id: speakerID, state: .skipped)
        XCTAssertTrue(await store.speakersAwaitingNames().isEmpty, "Skip means never ask again")

        await store.setSpeakerPromptState(id: speakerID, state: .askLater)
        XCTAssertTrue(await store.speakersAwaitingNames().isEmpty,
                      "Ask later means ask after substantially more evidence, not immediately")

        // Three times the evidence brings it back.
        for _ in 0..<40 { _ = await store.attributeSpeaker(embedding: vector, seconds: 6) }
        XCTAssertEqual(await store.speakersAwaitingNames().count, 1)
    }

    func testRenamingKeepsThePreviousNameForCorrection() async throws {
        let store = try TestStore.make()
        let match = try XCTUnwrap(await store.attributeSpeaker(embedding: MessyCorpus.signature(for: "A"),
                                                               seconds: 6))
        await store.renameSpeaker(id: match.speakerID, to: "Alex")
        await store.renameSpeaker(id: match.speakerID, to: "Alexandra")

        let speaker = try XCTUnwrap(await store.speaker(id: match.speakerID))
        XCTAssertEqual(speaker.displayName, "Alexandra")
        XCTAssertTrue(speaker.isNamed)
        XCTAssertTrue(speaker.previousNames.contains("Alex"),
                      "A correction must leave a trail, not erase the mistake")
    }

    /// Two clusters that were the same person all along.
    func testMergingSpeakersMovesTranscriptsAndDropsTheAbsorbedRow() async throws {
        let store = try TestStore.make()
        let sessionID = UUID()
        await store.startSession(id: sessionID, at: Date(), inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)

        let keep = try XCTUnwrap(await store.attributeSpeaker(embedding: MessyCorpus.signature(for: "A"),
                                                              seconds: 6))
        let absorb = try XCTUnwrap(await store.attributeSpeaker(embedding: MessyCorpus.signature(for: "B"),
                                                                seconds: 6))
        await store.renameSpeaker(id: keep.speakerID, to: "Alex")

        let lineID = UUID()
        await store.insertTranscript(id: lineID,
                                     sessionID: sessionID,
                                     audioSegmentID: nil,
                                     speakerID: absorb.speakerID,
                                     speakerConfidence: 0.6,
                                     startedAt: Date(),
                                     endedAt: Date().addingTimeInterval(4),
                                     index: 0,
                                     text: "this was the same person all along",
                                     confidence: 0.8,
                                     audioQuality: 0.7,
                                     assertion: .stated,
                                     languageCode: "en-US",
                                     wordTimings: [],
                                     isLowConfidence: false)

        await store.mergeSpeakers(keep: keep.speakerID, absorb: absorb.speakerID)

        XCTAssertEqual(await store.speakers().count, 1)
        let line = try XCTUnwrap(await store.transcriptLine(id: lineID))
        XCTAssertEqual(line.speakerID, keep.speakerID)
        XCTAssertEqual(line.speakerLabel, "Alex")
    }

    func testReassigningASegmentToUnknownIsAllowed() async throws {
        let store = try TestStore.make()
        let sessionID = UUID()
        await store.startSession(id: sessionID, at: Date(), inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)
        let match = try XCTUnwrap(await store.attributeSpeaker(embedding: MessyCorpus.signature(for: "A"),
                                                               seconds: 6))
        let lineID = UUID()
        await store.insertTranscript(id: lineID, sessionID: sessionID, audioSegmentID: nil,
                                     speakerID: match.speakerID, speakerConfidence: 0.4,
                                     startedAt: Date(), endedAt: Date().addingTimeInterval(3),
                                     index: 0, text: "who said that", confidence: 0.7,
                                     audioQuality: 0.6, assertion: .stated, languageCode: nil,
                                     wordTimings: [], isLowConfidence: false)

        await store.reassignSpeaker(segmentID: lineID, to: nil)
        let line = try XCTUnwrap(await store.transcriptLine(id: lineID))
        XCTAssertNil(line.speakerID)
        XCTAssertTrue(line.speakerIsUnknown)
    }
}

// MARK: - Transcripts and conversations

final class ConversationStoreTests: XCTestCase {

    private func makeSession(_ store: ClipperStore, at date: Date) async -> UUID {
        let id = UUID()
        await store.startSession(id: id, at: date, inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)
        return id
    }

    @discardableResult
    private func addLine(_ store: ClipperStore,
                         session: UUID,
                         at offset: Double,
                         base: Date,
                         text: String,
                         index: Int,
                         topicShift: Bool = false) async -> (line: UUID, conversation: UUID) {
        let startedAt = base.addingTimeInterval(offset)
        let endedAt = startedAt.addingTimeInterval(4)
        let lineID = UUID()
        await store.insertTranscript(id: lineID, sessionID: session, audioSegmentID: nil,
                                     speakerID: nil, speakerConfidence: 0,
                                     startedAt: startedAt, endedAt: endedAt, index: index,
                                     text: text, confidence: 0.8, audioQuality: 0.7,
                                     assertion: .stated, languageCode: "en-US",
                                     wordTimings: [], isLowConfidence: false)
        let assignment = await store.assignConversation(segmentID: lineID,
                                                        sessionID: session,
                                                        startedAt: startedAt,
                                                        endedAt: endedAt,
                                                        speakerID: nil,
                                                        confidence: 0.8,
                                                        topicShift: topicShift)
        return (lineID, assignment.conversationID)
    }

    /// Lines close together are one conversation. This is the common case and must not
    /// fragment.
    func testCloseLinesJoinOneConversation() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)

        var ids = Set<UUID>()
        for index in 0..<5 {
            let result = await addLine(store, session: session, at: Double(index) * 10,
                                       base: base, text: "line \(index) about the same thing",
                                       index: index)
            ids.insert(result.conversation)
        }
        XCTAssertEqual(ids.count, 1)

        let conversation = try XCTUnwrap(await store.conversations().first)
        XCTAssertEqual(conversation.segmentCount, 5)
        XCTAssertTrue(conversation.isOpen)
    }

    /// A long silence is a conversation boundary.
    func testALongGapStartsANewConversation() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)

        let first = await addLine(store, session: session, at: 0, base: base,
                                  text: "before the gap", index: 0)
        let second = await addLine(store, session: session, at: 600, base: base,
                                   text: "long after the gap", index: 1)

        XCTAssertNotEqual(first.conversation, second.conversation)
        XCTAssertEqual(await store.conversations().count, 2)
    }

    /// A topic shift splits *only* once the current conversation is substantial — otherwise
    /// every second sentence would start a new one.
    func testTopicShiftSplitsOnlyAfterTheConversationIsSubstantial() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)

        let first = await addLine(store, session: session, at: 0, base: base,
                                  text: "one", index: 0)
        let early = await addLine(store, session: session, at: 8, base: base,
                                  text: "two", index: 1, topicShift: true)
        XCTAssertEqual(early.conversation, first.conversation,
                       "A shift two lines in is noise, not a new conversation")

        for index in 2..<5 {
            await addLine(store, session: session, at: Double(index) * 8, base: base,
                          text: "line \(index)", index: index)
        }
        let late = await addLine(store, session: session, at: 60, base: base,
                                 text: "completely different subject", index: 6, topicShift: true)
        XCTAssertNotEqual(late.conversation, first.conversation)
    }

    func testEndingASessionClosesItsConversations() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)
        await addLine(store, session: session, at: 0, base: base, text: "hello", index: 0)

        let closed = await store.closeConversations(sessionID: session,
                                                    at: base.addingTimeInterval(120))
        XCTAssertEqual(closed.count, 1)
        let conversation = try XCTUnwrap(await store.conversations().first)
        XCTAssertFalse(conversation.isOpen)
    }

    func testTranscriptEditsAreMarkedAndKeepTheOriginal() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)
        let result = await addLine(store, session: session, at: 0, base: base,
                                   text: "a roarer needs the migration script", index: 0)

        await store.editTranscript(id: result.line, text: "aurora needs the migration script")
        let line = try XCTUnwrap(await store.transcriptLine(id: result.line))
        XCTAssertEqual(line.text, "aurora needs the migration script")
        XCTAssertTrue(line.wasEdited)
    }

    func testTranscriptLinesPaginateInOrder() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let session = await makeSession(store, at: base)
        var conversationID = UUID()
        for index in 0..<10 {
            let result = await addLine(store, session: session, at: Double(index) * 5,
                                       base: base, text: "line \(index)", index: index)
            conversationID = result.conversation
        }

        let firstPage = await store.transcriptLines(conversationID: conversationID, limit: 4, offset: 0)
        let secondPage = await store.transcriptLines(conversationID: conversationID, limit: 4, offset: 4)
        XCTAssertEqual(firstPage.count, 4)
        XCTAssertEqual(secondPage.count, 4)
        XCTAssertEqual(firstPage.first?.text, "line 0")
        XCTAssertEqual(secondPage.first?.text, "line 4")
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
    }
}

// MARK: - Memories

final class MemoryStoreTests: XCTestCase {

    private func candidate(_ title: String,
                           detail: String = "",
                           kind: MemoryKind = .fact,
                           key: String,
                           supersede: Bool = false,
                           at date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                           sources: [UUID] = [UUID()]) -> MemoryCandidate {
        MemoryCandidate(kind: kind,
                        title: title,
                        detail: detail,
                        confidence: 0.6,
                        assertion: .stated,
                        importance: 0.4,
                        occurredAt: date,
                        sourceKind: .transcriptSegment,
                        sourceIDs: sources,
                        dedupeKey: key,
                        supersedeOnChange: supersede)
    }

    func testTheSameClaimTwiceReinforcesOneMemory() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try XCTUnwrap(await store.upsertMemory(candidate("Postgres for aurora", key: "k1", at: base)))
        let second = try XCTUnwrap(await store.upsertMemory(
            candidate("Postgres for aurora", key: "k1", at: base.addingTimeInterval(600))))

        XCTAssertEqual(first.id, second.id, "One claim, one row")
        XCTAssertEqual(second.occurrenceCount, 2)
        XCTAssertGreaterThan(second.confidence, first.confidence, "Repetition is evidence")
        XCTAssertGreaterThan(second.lastSeenAt, second.firstSeenAt)
        XCTAssertEqual(second.sourceIDs.count, 2, "Both sources are kept")
        XCTAssertEqual(await store.memories().count, 1)
    }

    /// The headline case: a decision that changes must supersede, keep its history, and
    /// leave a visible contradiction.
    func testAChangedDecisionSupersedesAndRecordsAContradiction() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let original = try XCTUnwrap(await store.upsertMemory(
            candidate("Use Postgres for aurora",
                      detail: "we decided we will use postgres for the aurora project",
                      kind: .decision, key: "decision:aurora", supersede: true, at: base)))

        let replacement = try XCTUnwrap(await store.upsertMemory(
            candidate("Use SQLite for aurora",
                      detail: "we are moving aurora to sqlite instead of postgres",
                      kind: .decision, key: "decision:aurora", supersede: true,
                      at: base.addingTimeInterval(4_000))))

        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertEqual(replacement.supersedesID, original.id)
        XCTAssertEqual(replacement.revision, original.revision + 1)

        let refetchedOriginal = try XCTUnwrap(await store.memory(id: original.id))
        XCTAssertEqual(refetchedOriginal.supersededByID, replacement.id)
        XCTAssertFalse(refetchedOriginal.isCurrent, "The old decision is history, not current")

        // The old text is still readable — nothing was overwritten.
        XCTAssertEqual(refetchedOriginal.title, "Use Postgres for aurora")

        let chain = await store.revisionChain(for: replacement.id)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain.first?.id, original.id)

        let contradictions = await store.contradictions(includeResolved: false)
        XCTAssertEqual(contradictions.count, 1)
        XCTAssertEqual(contradictions.first?.earlier?.id, original.id)
        XCTAssertEqual(contradictions.first?.later?.id, replacement.id)
    }

    /// Same key, different substance, but not a superseding kind: keep one row and drop the
    /// confidence, because the evidence disagrees with itself.
    func testDisagreeingEvidenceDowngradesRatherThanPickingASide() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await store.upsertMemory(candidate("The deadline",
                                               detail: "the aurora deadline is on friday",
                                               kind: .event, key: "event:deadline", at: base))
        let second = try XCTUnwrap(await store.upsertMemory(
            candidate("The deadline",
                      detail: "completely unrelated wording about sailing lessons in june",
                      kind: .event, key: "event:deadline", at: base.addingTimeInterval(60))))

        XCTAssertEqual(second.assertion, .uncertain,
                       "Conflicting detail must be labelled uncertain, not asserted")
        XCTAssertEqual(await store.memories().count, 1)
    }

    func testAMemoryWithNoSourcesIsLabelledUnsupported() async throws {
        let store = try TestStore.make()
        let memory = try XCTUnwrap(await store.upsertMemory(
            candidate("Where did this come from", key: "orphan", sources: [])))
        XCTAssertEqual(memory.assertion, .unsupported)
        XCTAssertTrue(memory.isUnsupported)
    }

    func testEmptyTitleOrKeyIsRejected() async throws {
        let store = try TestStore.make()
        XCTAssertNil(await store.upsertMemory(candidate("   ", key: "k")))
        XCTAssertNil(await store.upsertMemory(candidate("fine", key: "")))
        XCTAssertEqual(await store.memories().count, 0)
    }

    /// A user edit is a new revision, not an overwrite.
    func testUserEditsCreateANewRevision() async throws {
        let store = try TestStore.make()
        let original = try XCTUnwrap(await store.upsertMemory(candidate("Postgres for arora", key: "k")))
        let edited = try XCTUnwrap(await store.editMemory(id: original.id,
                                                          title: "Postgres for aurora",
                                                          detail: "fixed the mishearing"))

        XCTAssertNotEqual(edited.id, original.id)
        XCTAssertTrue(edited.isUserEdited)
        XCTAssertEqual(edited.assertion, .stated)
        XCTAssertEqual(edited.supersedesID, original.id)
        XCTAssertEqual(await store.memory(id: original.id)?.supersededByID, edited.id)
        XCTAssertFalse(edited.isUnsupported, "A user edit is support in itself")
    }

    func testUnresolvedItemsAreTheQuestionsAndOpenIssues() async throws {
        let store = try TestStore.make()
        _ = await store.upsertMemory(candidate("when is the deadline", kind: .question, key: "q1"))
        _ = await store.upsertMemory(candidate("the migration script is broken",
                                               kind: .unresolved, key: "u1"))
        _ = await store.upsertMemory(candidate("a plain fact", kind: .fact, key: "f1"))

        let unresolved = await store.unresolvedMemories()
        XCTAssertEqual(unresolved.count, 2)
        XCTAssertTrue(unresolved.allSatisfy { MemoryKind.unresolvedKinds.contains($0.kind) })
    }

    func testArchivedMemoriesLeaveTheCurrentSet() async throws {
        let store = try TestStore.make()
        let memory = try XCTUnwrap(await store.upsertMemory(candidate("noise", key: "n")))
        await store.setMemoryArchived(id: memory.id, archived: true)

        XCTAssertFalse(try XCTUnwrap(await store.memory(id: memory.id)).isCurrent)
        XCTAssertTrue(await store.memories().isEmpty)
    }

    func testMemoriesCitingATranscriptLineAreFindable() async throws {
        let store = try TestStore.make()
        let lineID = UUID()
        let memory = try XCTUnwrap(await store.upsertMemory(
            candidate("cited", key: "c", sources: [lineID])))

        let citing = await store.memoriesCiting(sourceID: lineID)
        XCTAssertEqual(citing.map(\.id), [memory.id])
        XCTAssertTrue(await store.memoriesCiting(sourceID: UUID()).isEmpty)
    }

    func testResolvingAContradictionArchivesTheLoser() async throws {
        let store = try TestStore.make()
        let a = try XCTUnwrap(await store.upsertMemory(candidate("earlier", key: "a")))
        let b = try XCTUnwrap(await store.upsertMemory(candidate("later", key: "b")))
        await store.recordContradiction(earlier: a.id, later: b.id,
                                        explanation: "these disagree", confidence: 0.7)

        var open = await store.contradictions(includeResolved: false)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(try XCTUnwrap(await store.memory(id: a.id)).assertion, .contradictory)

        await store.resolveContradiction(id: try XCTUnwrap(open.first).id, keeping: b.id)
        open = await store.contradictions(includeResolved: false)
        XCTAssertTrue(open.isEmpty)
        XCTAssertFalse(try XCTUnwrap(await store.memory(id: a.id)).isCurrent, "The loser is archived")
        XCTAssertTrue(try XCTUnwrap(await store.memory(id: b.id)).isCurrent)
    }

    func testRecordingTheSameContradictionTwiceIsIdempotent() async throws {
        let store = try TestStore.make()
        let a = try XCTUnwrap(await store.upsertMemory(candidate("earlier", key: "a")))
        let b = try XCTUnwrap(await store.upsertMemory(candidate("later", key: "b")))
        for _ in 0..<3 {
            await store.recordContradiction(earlier: a.id, later: b.id,
                                            explanation: "same thing", confidence: 0.7)
        }
        XCTAssertEqual(await store.contradictions(includeResolved: true).count, 1)
    }
}

// MARK: - Summaries

final class SummaryStoreTests: XCTestCase {

    private let draft = SummaryDraft(title: "Aurora planning",
                                     text: "The team settled on a database.",
                                     bullets: ["Chose Postgres", "Deadline on Friday"],
                                     confidence: 0.6,
                                     generator: "extractive")

    func testASummaryForTheSameScopeAndKeyIsUpdatedNotDuplicated() async throws {
        let store = try TestStore.make()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let sources = [UUID(), UUID()]

        let first = await store.upsertSummary(scope: .day, key: "2023-11-14", draft: draft,
                                              periodStart: day, periodEnd: day.addingTimeInterval(86_400),
                                              sourceKind: .conversation, sourceIDs: sources)
        var updated = draft
        updated.text = "The team changed its mind about the database."
        let second = await store.upsertSummary(scope: .day, key: "2023-11-14", draft: updated,
                                               periodStart: day, periodEnd: day.addingTimeInterval(86_400),
                                               sourceKind: .conversation, sourceIDs: sources)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.revision, first.revision + 1)
        XCTAssertEqual(second.text, "The team changed its mind about the database.")
        XCTAssertEqual(await store.summaries(scope: .day).count, 1)
    }

    func testTheSameKeyInADifferentScopeIsADifferentSummary() async throws {
        let store = try TestStore.make()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let a = await store.upsertSummary(scope: .day, key: "shared", draft: draft,
                                          periodStart: day, periodEnd: day,
                                          sourceKind: .conversation, sourceIDs: [UUID()])
        let b = await store.upsertSummary(scope: .week, key: "shared", draft: draft,
                                          periodStart: day, periodEnd: day,
                                          sourceKind: .conversation, sourceIDs: [UUID()])
        XCTAssertNotEqual(a.id, b.id)
    }

    func testASummaryWithoutSourcesIsUnsupported() async throws {
        let store = try TestStore.make()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = await store.upsertSummary(scope: .day, key: "empty", draft: draft,
                                                periodStart: day, periodEnd: day,
                                                sourceKind: .conversation, sourceIDs: [])
        XCTAssertEqual(summary.assertion, .unsupported)
    }

    func testSummaryWithSourcesIsLabelledSummarised() async throws {
        let store = try TestStore.make()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = await store.upsertSummary(scope: .day, key: "full", draft: draft,
                                                periodStart: day, periodEnd: day,
                                                sourceKind: .conversation, sourceIDs: [UUID()])
        XCTAssertEqual(summary.assertion, .summarised)
        XCTAssertEqual(summary.generator, "extractive")
        XCTAssertEqual(summary.bullets.count, 2)
    }
}

// MARK: - Brain map

final class GraphStoreTests: XCTestCase {

    func testNodesAreIdentifiedByNormalisedNameAndKind() async throws {
        let store = try TestStore.make()
        let first = try XCTUnwrap(await store.upsertNode(kind: .project, name: "Aurora"))
        let second = try XCTUnwrap(await store.upsertNode(kind: .project, name: "  aurora  "))
        XCTAssertEqual(first, second, "Case and padding must not create a second node")

        let topic = try XCTUnwrap(await store.upsertNode(kind: .topic, name: "Aurora"))
        XCTAssertNotEqual(first, topic, "A project and a topic with the same name are different")

        let node = try XCTUnwrap(await store.node(id: first))
        XCTAssertEqual(node.mentionCount, 2)
    }

    func testOneCharacterNamesAreRejected() async throws {
        let store = try TestStore.make()
        XCTAssertNil(await store.upsertNode(kind: .topic, name: "a"))
        XCTAssertNil(await store.upsertNode(kind: .topic, name: "  "))
    }

    func testEdgesAccumulateWeightAndCarryEvidence() async throws {
        let store = try TestStore.make()
        let alex = try XCTUnwrap(await store.upsertNode(kind: .person, name: "Alex"))
        let aurora = try XCTUnwrap(await store.upsertNode(kind: .project, name: "Aurora"))
        let evidence = UUID()

        await store.upsertEdge(source: alex, target: aurora, kind: .mentions,
                               confidence: 0.5, evidenceIDs: [evidence])
        await store.upsertEdge(source: alex, target: aurora, kind: .mentions,
                               confidence: 0.8, evidenceIDs: [UUID()])

        let subgraph = try XCTUnwrap(await store.subgraph(around: alex))
        XCTAssertEqual(subgraph.focus.id, alex)
        XCTAssertEqual(subgraph.edges.count, 1, "The same pair and kind is one edge")
        let edge = try XCTUnwrap(subgraph.edges.first)
        XCTAssertEqual(edge.weight, 2, accuracy: 0.001)
        XCTAssertEqual(edge.confidence, 0.8, accuracy: 0.001, "Confidence is the best seen")
        XCTAssertTrue(edge.isExplainable)
        XCTAssertTrue(edge.evidenceIDs.contains(evidence))
    }

    func testSelfEdgesAreIgnored() async throws {
        let store = try TestStore.make()
        let node = try XCTUnwrap(await store.upsertNode(kind: .topic, name: "sailing"))
        await store.upsertEdge(source: node, target: node, kind: .relatedTo)
        XCTAssertTrue(try XCTUnwrap(await store.subgraph(around: node)).edges.isEmpty)
    }

    /// The brain map must never fetch the whole graph.
    func testSubgraphIsBoundedAndSignalsThatMoreExists() async throws {
        let store = try TestStore.make()
        let focus = try XCTUnwrap(await store.upsertNode(kind: .person, name: "Alex"))
        for index in 0..<30 {
            let other = try XCTUnwrap(await store.upsertNode(kind: .topic, name: "topic-\(index)"))
            await store.upsertEdge(source: focus, target: other, kind: .mentions,
                                   evidenceIDs: [UUID()])
        }

        let subgraph = try XCTUnwrap(await store.subgraph(around: focus, maxNeighbours: 5))
        XCTAssertLessThanOrEqual(subgraph.neighbours.count, 5)
        XCTAssertTrue(subgraph.hasMore, "The UI must be told it is seeing a slice")
    }

    func testSubgraphOfAnUnknownNodeIsNil() async throws {
        let store = try TestStore.make()
        XCTAssertNil(await store.subgraph(around: UUID()))
    }

    func testMemoriesAreReachableFromANode() async throws {
        let store = try TestStore.make()
        let node = try XCTUnwrap(await store.upsertNode(kind: .project, name: "Aurora"))
        let memory = try XCTUnwrap(await store.upsertMemory(
            MemoryCandidate(kind: .decision, title: "Use Postgres", confidence: 0.7,
                            assertion: .stated, importance: 0.5,
                            sourceIDs: [UUID()], nodeIDs: [node], dedupeKey: "d")))

        let found = await store.memories(nodeID: node, limit: 10)
        XCTAssertEqual(found.map(\.id), [memory.id])
    }
}

// MARK: - Job queue

final class JobQueueTests: XCTestCase {

    /// A queued utterance, built the way the segmenter would build it.
    private func utterance(_ id: UUID = UUID(), snr: Double = 12) -> String {
        let pending = PendingUtterance(id: id,
                                       sessionID: UUID(),
                                       index: 1,
                                       startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       endedAt: Date(timeIntervalSince1970: 1_700_000_004),
                                       url: URL(fileURLWithPath: "/tmp/\(id).wav"),
                                       sampleRate: 16_000,
                                       frameCount: 64_000,
                                       meanSNRDB: snr,
                                       peakLevelDB: -10,
                                       noiseFloorDB: -45,
                                       speechRatio: 0.7,
                                       continuesPrevious: false,
                                       truncated: false)
        return UtterancePayload(utterance: pending).json
    }

    func testJobsAreClaimedByPriorityThenAge() async throws {
        let store = try TestStore.make()
        let low = RollupPayload(key: "2023-11-14").json
        let high = utterance()

        await store.enqueueJob(kind: .rollupDay, payload: low, priority: 1)
        await store.enqueueJob(kind: .processUtterance, payload: high, priority: 10)

        let first = try XCTUnwrap(await store.claimNextJob())
        XCTAssertEqual(first.kind, .processUtterance,
                       "Live audio must not wait behind a nightly rollup")
        XCTAssertEqual(first.payload, high)
        XCTAssertEqual(first.attempts, 1)

        let second = try XCTUnwrap(await store.claimNextJob())
        XCTAssertEqual(second.payload, low)
        XCTAssertNil(await store.claimNextJob())
    }

    /// Closing the same conversation twice must not summarise it twice.
    func testEnqueuingAnIdenticalJobTwiceIsDeduped() async throws {
        let store = try TestStore.make()
        let payload = ConversationPayload(conversationID: UUID()).json
        var accepted = 0
        for _ in 0..<5 {
            if await store.enqueueJob(kind: .closeConversation, payload: payload, priority: 2) != nil {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(await store.pendingJobCount(), 1)
    }

    /// The same *kind* with a different payload is different work and must both queue.
    func testDifferentPayloadsOfTheSameKindBothQueue() async throws {
        let store = try TestStore.make()
        await store.enqueueJob(kind: .processUtterance, payload: utterance(), priority: 5)
        await store.enqueueJob(kind: .processUtterance, payload: utterance(), priority: 5)
        XCTAssertEqual(await store.pendingJobCount(), 2)
    }

    func testAFailingJobRetriesUntilItsAttemptCapThenStops() async throws {
        let store = try TestStore.make()
        await store.enqueueJob(kind: .processUtterance, payload: utterance(), priority: 5)

        var attempts = 0
        while let job = await store.claimNextJob(), attempts < 10 {
            attempts += 1
            await store.failJob(id: job.id, error: "synthetic failure")
        }

        XCTAssertEqual(attempts, JobRecord.maxAttempts,
                       "A job that always fails must stop, not spin forever")
        XCTAssertEqual(await store.failedJobs().count, 1)
        XCTAssertEqual(await store.pendingJobCount(), 0)

        // The user can ask for a retry explicitly, from Diagnostics.
        let retried = await store.retryFailedJobs()
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(await store.pendingJobCount(), 1)
    }

    /// Killed mid-job, the row is left `running`. The next launch must put it back.
    func testStrandedRunningJobsAreRequeuedOnBootstrap() async throws {
        let store = try TestStore.make()
        await store.enqueueJob(kind: .processUtterance, payload: utterance(), priority: 5)
        _ = await store.claimNextJob()
        XCTAssertEqual(await store.pendingJobCount(), 1, "A running job still counts as outstanding")

        let reset = await store.resetStrandedJobs()
        XCTAssertEqual(reset, 1)
        XCTAssertNotNil(await store.claimNextJob(), "It must be claimable again")
    }

    func testFinishedJobsLeaveTheQueueAndCanBePruned() async throws {
        let store = try TestStore.make()
        await store.enqueueJob(kind: .processUtterance, payload: utterance(), priority: 5)
        let job = try XCTUnwrap(await store.claimNextJob())
        await store.finishJob(id: job.id)

        XCTAssertEqual(await store.pendingJobCount(), 0)
        XCTAssertTrue(await store.failedJobs().isEmpty)

        await store.pruneFinishedJobs(olderThan: -1)
        XCTAssertEqual(await store.stats().pendingJobs, 0)
    }

    func testCancellingAJobRemovesItFromTheQueue() async throws {
        let store = try TestStore.make()
        await store.enqueueJob(kind: .rollupDay, payload: RollupPayload(key: "k").json, priority: 1)
        let pending = await store.pendingJobs(kind: .rollupDay, limit: 10)
        XCTAssertEqual(pending.count, 1)

        await store.cancelJob(id: try XCTUnwrap(pending.first).id, reason: "user cancelled")
        XCTAssertEqual(await store.pendingJobCount(), 0)
    }

    /// Backpressure needs to know which utterances are still queued so it can drop the
    /// worst one rather than the newest one.
    func testLiveUtteranceIDsReportsOnlyPendingUtteranceWork() async throws {
        let store = try TestStore.make()
        let first = UUID()
        let second = UUID()
        await store.enqueueJob(kind: .rollupDay, payload: RollupPayload(key: "k").json, priority: 1)
        await store.enqueueJob(kind: .processUtterance, payload: utterance(first), priority: 5)
        await store.enqueueJob(kind: .processUtterance, payload: utterance(second), priority: 5)

        let live = await store.liveUtteranceIDs()
        XCTAssertEqual(live, [first, second],
                       "Only utterance work holds audio files open")
    }

    /// Payload round-tripping is what makes the queue durable across launches.
    func testPayloadsSurviveTheRoundTripThroughTheQueue() async throws {
        let store = try TestStore.make()
        let id = UUID()
        await store.enqueueJob(kind: .processUtterance, payload: utterance(id, snr: 17.5), priority: 5)

        let job = try XCTUnwrap(await store.claimNextJob())
        let decoded = try XCTUnwrap(UtterancePayload(json: job.payload))
        XCTAssertEqual(decoded.utteranceID, id)
        XCTAssertEqual(decoded.meanSNRDB, 17.5, accuracy: 0.001)
        XCTAssertEqual(decoded.duration, 4, accuracy: 0.001)
        XCTAssertEqual(decoded.filename, "\(id).wav")
    }
}

// MARK: - Wholesale deletion

final class StoreErasureTests: XCTestCase {

    func testDeleteEverythingLeavesAUsableEmptyStore() async throws {
        let store = try TestStore.make()
        await MessyCorpus.load(into: store)
        _ = await MessyCorpus.closeAndBuildMemories(in: store)

        var stats = await store.stats()
        XCTAssertGreaterThan(stats.transcriptSegments, 0)
        XCTAssertGreaterThan(stats.documents, 0)

        await store.deleteEverything()
        stats = await store.stats()
        XCTAssertEqual(stats.sessions, 0)
        XCTAssertEqual(stats.transcriptSegments, 0)
        XCTAssertEqual(stats.conversations, 0)
        XCTAssertEqual(stats.memories, 0)
        XCTAssertEqual(stats.speakers, 0)
        XCTAssertEqual(stats.documents, 0)
        XCTAssertEqual(stats.postings, 0)
        XCTAssertEqual(stats.nodes, 0)
        XCTAssertEqual(stats.edges, 0)

        // And the store still works afterwards.
        let id = UUID()
        await store.startSession(id: id, at: Date(), inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)
        XCTAssertEqual(await store.sessions().count, 1)
    }
}
