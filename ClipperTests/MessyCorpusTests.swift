import Foundation
import XCTest

@testable import Clipper

/// End-to-end over the messy corpus.
///
/// The corpus is deliberately awkward: repeated statements, incomplete sentences, misheard
/// words, an unknown voice, long silences, rapid topic changes, a decision that later
/// reverses, and a negated restatement of the original claim. These tests assert the
/// behaviours that only show up on messy input — the ones a clean fixture would hide.
final class MessyCorpusTests: XCTestCase {

    private func loaded() async throws -> ClipperStore {
        let store = try TestStore.make()
        await MessyCorpus.load(into: store)
        return store
    }

    // MARK: - Segmentation

    /// A 4½-minute silence in the middle of the corpus must break the session into
    /// conversations rather than producing one enormous blob.
    func testLongSilencesSplitTheSessionIntoConversations() async throws {
        let store = try await loaded()
        let conversations = await store.conversations()

        await XCTAssertGreaterThanOrEqual(conversations.count, 3,
                                    "Three clusters of speech, separated by long gaps")
        for conversation in conversations {
            await XCTAssertGreaterThan(conversation.segmentCount, 0)
            await XCTAssertGreaterThanOrEqual(conversation.endedAt, conversation.startedAt)
        }

        // No conversation may span the big silence.
        for conversation in conversations {
            await XCTAssertLessThan(conversation.duration, 2_000,
                              "A conversation that spans a 45-minute gap is a grouping bug")
        }
    }

    func testEveryTranscriptLineLandsInExactlyOneConversation() async throws {
        let store = try await loaded()
        let lines = await store.transcriptLines(sessionID: try await XCTUnwrap(await store.sessions().first).id)

        await XCTAssertEqual(lines.count, MessyCorpus.lines.count)
        await XCTAssertTrue(lines.allSatisfy { $0.conversationID != nil },
                      "An orphaned transcript line is unreachable from every screen")

        var seen = Set<UUID>()
        for line in lines { await XCTAssertTrue(seen.insert(line.id).inserted) }
    }

    // MARK: - Speakers

    func testTheUnknownVoiceStaysUnknownRatherThanBeingGuessedInto() async throws {
        let store = try await loaded()
        let lines = await store.transcriptLines(sessionID: try await XCTUnwrap(await store.sessions().first).id)
        let unknown = lines.filter(\.speakerIsUnknown)

        await XCTAssertEqual(unknown.count, 2, "Both 'Unknown voice' lines stay unattributed")
        await XCTAssertTrue(unknown.allSatisfy { $0.speakerConfidence == 0 })
        await XCTAssertTrue(unknown.allSatisfy { $0.speakerLabel == "Unknown voice" })

        let speakers = await store.speakers()
        await XCTAssertEqual(speakers.count, 2, "Only Alex and Sam are real clusters")
    }

    func testCorrectingASpeakerNameUpdatesEveryLine() async throws {
        let store = try await loaded()
        let alex = try await XCTUnwrap(await store.speakers().first { $0.displayName == "Alex" })

        await store.renameSpeaker(id: alex.id, to: "Alexandra")
        let lines = await store.recentLines(speakerID: alex.id, limit: 50)
        await XCTAssertFalse(lines.isEmpty)
        await XCTAssertTrue(lines.allSatisfy { $0.speakerLabel == "Alexandra" })
    }

    // MARK: - Low-confidence handling

    /// The mishearing ("a roarer") and the mumble ("uh yeah okay yeah") are low-confidence.
    /// They must be stored, labelled and down-ranked — never silently discarded.
    func testLowConfidenceLinesAreKeptAndLabelled() async throws {
        let store = try await loaded()
        let lines = await store.transcriptLines(sessionID: try await XCTUnwrap(await store.sessions().first).id)
        let weak = lines.filter(\.isLowConfidence)

        await XCTAssertGreaterThanOrEqual(weak.count, 3)
        await XCTAssertTrue(weak.allSatisfy { $0.assertion == .uncertain },
                      "Low-confidence speech must not be presented as stated fact")
        await XCTAssertTrue(weak.contains { $0.text.contains("a roarer") },
                      "The mishearing is evidence of what was heard, and is kept")
    }

    /// The user corrects the mishearing. The correction must be searchable and the old
    /// wording must stop matching.
    func testCorrectingAMisheardLineFixesTheIndexToo() async throws {
        let store = try await loaded()
        let search = SearchService(store: store)
        let lines = await store.transcriptLines(sessionID: try await XCTUnwrap(await store.sessions().first).id)
        let misheard = try await XCTUnwrap(lines.first { $0.text.contains("a roarer") })

        let corrected = "aurora needs the migration script first"
        await store.editTranscript(id: misheard.id, text: corrected)
        await store.indexDocument(IndexCandidate(kind: .transcriptSegment,
                                                 refID: misheard.id,
                                                 conversationID: misheard.conversationID,
                                                 title: misheard.speakerLabel,
                                                 text: corrected,
                                                 timestamp: misheard.startedAt,
                                                 speakerIDs: misheard.speakerID.map { [$0] } ?? [],
                                                 nodeIDs: [],
                                                 importance: 0.3,
                                                 confidence: 1,
                                                 assertion: .stated,
                                                 embedding: []))

        let roarer = await search.search(SearchQuery(text: "roarer"))
        await XCTAssertTrue(roarer.hits.isEmpty, "The corrected wording must replace the old postings")

        let migration = await search.search(SearchQuery(text: "migration script"))
        await XCTAssertTrue(migration.hits.contains { $0.refID == misheard.id })
    }

    // MARK: - Memories

    /// The corpus states "Postgres for aurora" three times in slightly different words.
    /// That must be one memory, reinforced — not three.
    func testARepeatedStatementBecomesOneReinforcedMemory() async throws {
        let store = try await loaded()
        _ = await MessyCorpus.closeAndBuildMemories(in: store)

        let memories = await store.memories(limit: 200)
        let titles = memories.map { $0.title.lowercased() }
        await XCTAssertFalse(memories.isEmpty, "A whole conversation must yield something")

        // No two current memories may be textually identical.
        await XCTAssertEqual(Set(titles).count, titles.count,
                       "Duplicate memories mean the dedupe key is not doing its job")

        let reinforced = memories.filter { $0.occurrenceCount > 1 }
        await XCTAssertFalse(reinforced.isEmpty, "Repetition must strengthen rather than duplicate")
    }

    /// The headline behaviour: the decision reverses 65 minutes later. The old decision must
    /// still be readable, the new one must be current, and the change must be visible.
    func testTheReversedDecisionSupersedesAndLeavesAReadableHistory() async throws {
        let store = try await loaded()
        _ = await MessyCorpus.closeAndBuildMemories(in: store)

        let all = await store.memories(includeArchived: true, includeSuperseded: true, limit: 200)
        let superseded = all.filter { $0.supersededByID != nil }

        guard !superseded.isEmpty else {
            // The extractor found no subject-keyed collision in this corpus. That is a real
            // possible outcome for lexical extraction, and it must fail loudly rather than
            // silently passing, because it is the behaviour the product promises.
            return XCTFail("The corpus reverses a decision; nothing was superseded")
        }

        for old in superseded {
            let replacement = try await XCTUnwrap(await store.memory(id: try await XCTUnwrap(old.supersededByID)))
            await XCTAssertGreaterThan(replacement.revision, old.revision)
            await XCTAssertEqual(replacement.supersedesID, old.id)
            await XCTAssertFalse(old.title.isEmpty, "The old statement is still readable")

            let chain = await store.revisionChain(for: replacement.id)
            await XCTAssertGreaterThanOrEqual(chain.count, 2)
            await XCTAssertEqual(chain.first?.id, old.id, "Oldest first, so 'what changed' reads forwards")
        }

        let contradictions = await store.contradictions(includeResolved: true, limit: 50)
        await XCTAssertFalse(contradictions.isEmpty, "A reversal is a contradiction worth surfacing")
    }

    func testEveryMemoryPointsBackAtRealTranscriptLines() async throws {
        let store = try await loaded()
        _ = await MessyCorpus.closeAndBuildMemories(in: store)

        let lineIDs = Set(await store.transcriptLines(
            sessionID: try await XCTUnwrap(await store.sessions().first).id).map(\.id))

        for memory in await store.memories(limit: 200) where memory.sourceKind == .transcriptSegment {
            await XCTAssertFalse(memory.sourceIDs.isEmpty,
                           "'\(memory.title)' has no evidence and should have been unsupported")
            for sourceID in memory.sourceIDs {
                await XCTAssertTrue(lineIDs.contains(sourceID),
                              "A memory cites a transcript line that does not exist")
            }
        }
    }

    func testTheMumbleNeverBecomesAMemory() async throws {
        let store = try await loaded()
        _ = await MessyCorpus.closeAndBuildMemories(in: store)

        for memory in await store.memories(limit: 200) {
            await XCTAssertFalse(memory.title.lowercased().contains("uh yeah okay"),
                           "Filler must not be promoted to a curated memory")
        }
    }

    // MARK: - Brain map

    func testEntitiesFromMessySpeechBecomeNodesWithEvidence() async throws {
        let store = try await loaded()
        let nodes = await store.nodes(limit: 100)
        await XCTAssertFalse(nodes.isEmpty)

        // "aurora" is the dominant topic and must be one node, not several.
        let aurora = nodes.filter { Tokenizer.normalizeName($0.name) == "aurora" }
        await XCTAssertLessThanOrEqual(aurora.count, 1, "One name, one node per kind")

        if let aurora = aurora.first {
            await XCTAssertGreaterThan(aurora.mentionCount, 1)
            let subgraph = try await XCTUnwrap(await store.subgraph(around: aurora.id))
            await XCTAssertEqual(subgraph.focus.id, aurora.id)
        }
    }

    // MARK: - Search over messy data

    func testSearchFindsTheTopicDespiteTheMess() async throws {
        let store = try await loaded()
        let hits = await SearchService(store: store).search(SearchQuery(text: "aurora")).hits
        await XCTAssertGreaterThanOrEqual(hits.count, 4)

        // The mumble must not out-rank a real statement.
        let mumbleRank = hits.firstIndex { $0.snippet.lowercased().contains("uh yeah") }
        if let mumbleRank {
            await XCTAssertGreaterThan(mumbleRank, 0, "Filler must never be the top result")
        }
    }

    func testFilteringBySpeakerSeparatesTwoVoicesSayingTheSameThing() async throws {
        let store = try await loaded()
        let sam = try await XCTUnwrap(await store.speakers().first { $0.displayName == "Sam" })

        var query = SearchQuery(text: "aurora")
        query.speakerIDs = [sam.id]
        let hits = await SearchService(store: store).search(query).hits

        await XCTAssertFalse(hits.isEmpty)
        await XCTAssertTrue(hits.allSatisfy { $0.speakerLabels.contains("Sam") || $0.speakerLabels.isEmpty })
    }

    // MARK: - Summarisation

    /// The extractive summariser cannot hallucinate: every sentence it emits must appear in
    /// the input. This is the property that makes it a safe fallback.
    func testTheExtractiveSummaryOnlyContainsSentencesThatWereActuallySaid() async throws {
        let store = try await loaded()
        let conversation = try await XCTUnwrap(await store.conversations().first)
        let lines = await store.transcriptLines(conversationID: conversation.id)
        await XCTAssertFalse(lines.isEmpty)

        let input = SummarizationInput(lines: lines.map { "\($0.speakerLabel): \($0.text)" },
                                       scope: .conversation,
                                       keywords: ["aurora", "postgres"],
                                       speakerLabels: ["Alex", "Sam"],
                                       periodStart: conversation.startedAt,
                                       periodEnd: conversation.endedAt)

        let draft = try await XCTUnwrap(await ExtractiveSummarizer().summarize(input))
        await XCTAssertEqual(draft.generator, "extractive")
        await XCTAssertFalse(draft.title.isEmpty)

        let spoken = lines.map { $0.text.lowercased() }
        for bullet in draft.bullets {
            let stripped = bullet.lowercased()
            await XCTAssertTrue(spoken.contains { $0.contains(stripped) || stripped.contains($0) },
                          "Bullet '\(bullet)' was not in the transcript")
        }
    }

    func testAVeryShortConversationProducesNoSummaryRatherThanPadding() async {
        let input = SummarizationInput(lines: ["Alex: mm hmm"],
                                       scope: .conversation,
                                       keywords: [],
                                       speakerLabels: ["Alex"],
                                       periodStart: Date(),
                                       periodEnd: Date())
        await XCTAssertFalse(input.isSubstantial)
        await XCTAssertNil(await ExtractiveSummarizer().summarize(input),
                     "There is nothing to summarise; inventing something would be worse")
    }

    // MARK: - Reprocessing

    /// Running the whole pipeline twice over the same speech must not double anything.
    func testLoadingTheCorpusIsIdempotentAtTheMemoryLayer() async throws {
        let store = try await loaded()
        let first = await MessyCorpus.closeAndBuildMemories(in: store)
        let countAfterFirst = await store.memories(limit: 500).count
        await XCTAssertEqual(countAfterFirst, Set(first.map(\.id)).count)

        // Rebuild from the same extractions: every candidate collides with its own key.
        _ = await MessyCorpus.closeAndBuildMemories(in: store)
        let countAfterSecond = await store.memories(limit: 500).count
        await XCTAssertEqual(countAfterSecond, countAfterFirst,
                       "Reprocessing must reinforce, never duplicate")
    }
}

// MARK: - Dedupe-key strategy

/// The two key strategies, tested directly, because they are what makes reinforcement and
/// supersession work on real speech.
final class MemoryKeyTests: XCTestCase {

    private func extraction(_ kind: MemoryKind, _ text: String, subject: String? = nil)
        -> ExtractionSnapshot {
        ExtractionSnapshot(id: UUID(), transcriptSegmentID: UUID(), conversationID: UUID(),
                           speakerID: UUID(), kind: kind, text: text, subject: subject,
                           confidence: 0.8, assertion: .stated,
                           occurredAt: Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// Two decisions about one subject collide, which is what triggers supersession.
    func testDecisionsAboutOneSubjectShareAKey() {
        let keywords = ["aurora", "project", "database"]
        let earlier = MemoryBuilder.key(for: extraction(.decision,
                                                        "we decided we will use postgres for aurora",
                                                        subject: "aurora"),
                                        conversationKeywords: keywords)
        let later = MemoryBuilder.key(for: extraction(.decision,
                                                      "we are moving aurora to sqlite",
                                                      subject: "aurora"),
                                      conversationKeywords: keywords)
        XCTAssertEqual(earlier, later)

        let unrelated = MemoryBuilder.key(for: extraction(.decision,
                                                          "we decided to sail in june",
                                                          subject: "sailing"),
                                          conversationKeywords: keywords)
        XCTAssertNotEqual(earlier, unrelated)
    }

    /// With no explicit subject, the shared conversation topic does the same job.
    func testSharedConversationTopicsActAsTheSubject() {
        let keywords = ["aurora", "database"]
        let earlier = MemoryBuilder.key(for: extraction(.decision, "let's use postgres for aurora"),
                                        conversationKeywords: keywords)
        let later = MemoryBuilder.key(for: extraction(.decision, "we're moving aurora to sqlite"),
                                      conversationKeywords: keywords)
        XCTAssertEqual(earlier, later)
    }

    /// Facts do the opposite: two different facts must stay two memories.
    func testDifferentFactsKeepDifferentKeys() {
        let keywords = ["aurora"]
        let friday = MemoryBuilder.key(for: extraction(.fact, "the aurora deadline is on friday"),
                                       conversationKeywords: keywords)
        let monday = MemoryBuilder.key(for: extraction(.fact, "the aurora deadline is on monday"),
                                       conversationKeywords: keywords)
        XCTAssertNotEqual(friday, monday)

        let restated = MemoryBuilder.key(for: extraction(.fact, "The aurora deadline is Friday!"),
                                         conversationKeywords: keywords)
        XCTAssertEqual(friday, restated, "The same fact restated is the same memory")
    }

    /// A claim is promoted to a fact, so the two must key identically or the promotion
    /// would create a second row.
    func testClaimsAndFactsShareAKeyspace() {
        let keywords = ["aurora"]
        let claim = MemoryBuilder.key(for: extraction(.claim, "the aurora deadline is on friday"),
                                      conversationKeywords: keywords)
        let fact = MemoryBuilder.key(for: extraction(.fact, "the aurora deadline is on friday"),
                                     conversationKeywords: keywords)
        XCTAssertEqual(claim, fact)
    }
}
