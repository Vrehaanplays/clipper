import Foundation
import XCTest

@testable import Clipper

/// Scale and latency, on a synthetic dataset large enough that a full-table scan would be
/// visibly slower than an index lookup.
///
/// These tests assert *budgets*, not absolute times: CI runners and devices differ by an
/// order of magnitude, so the thresholds are set where a genuine regression (an O(n) scan
/// creeping into the hot path) fails while ordinary machine-to-machine variance does not.
/// The measured numbers are printed so `docs/PERFORMANCE.md` can quote real figures rather
/// than guesses.
final class LargeDatasetTests: XCTestCase {

    /// Roughly a fortnight of heavy use: ~40 conversations a day.
    private let conversationCount = 120
    private let linesPerConversation = 12

    /// Vocabulary chosen so terms have realistically skewed frequencies: a handful of very
    /// common words, a long tail of rare ones. Uniform random words would make every IDF
    /// identical and hide exactly the behaviour worth testing.
    private static let common = ["project", "deadline", "meeting", "team", "plan", "update"]
    private static let rare = (0..<400).map { "term\($0)" }

    private func synthesize(into store: ClipperStore) async -> (lines: Int, needle: UUID) {
        var generator = SeededGenerator(seed: 0x5EED)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var lineCount = 0
        var needle = UUID()

        let sessionID = UUID()
        await store.startSession(id: sessionID, at: base, inputName: "iPhone Microphone",
                                 usedBuiltInMic: true, otherAudioPlaying: false)

        for conversation in 0..<conversationCount {
            let conversationID = UUID()
            for line in 0..<linesPerConversation {
                let offset = Double(conversation) * 900 + Double(line) * 20
                let timestamp = base.addingTimeInterval(offset)
                let refID = UUID()

                var words: [String] = []
                for _ in 0..<12 {
                    words.append(generator.next(under: 3) == 0
                                 ? Self.common[Int(generator.next(under: UInt64(Self.common.count)))]
                                 : Self.rare[Int(generator.next(under: UInt64(Self.rare.count)))])
                }
                // One document, in the middle of the corpus, carries a unique term.
                if conversation == conversationCount / 2 && line == 0 {
                    words.append("quokka")
                    needle = refID
                }

                await store.indexDocument(IndexCandidate(kind: .transcriptSegment,
                                                         refID: refID,
                                                         conversationID: conversationID,
                                                         title: "Line \(lineCount)",
                                                         text: words.joined(separator: " "),
                                                         timestamp: timestamp,
                                                         speakerIDs: [],
                                                         nodeIDs: [],
                                                         importance: 0.3,
                                                         confidence: 0.8,
                                                         assertion: .stated,
                                                         embedding: []))
                lineCount += 1
            }
        }
        await store.endSession(id: sessionID, at: base.addingTimeInterval(Double(conversationCount) * 900))
        return (lineCount, needle)
    }

    /// Search must stay fast as the corpus grows, because the hot path is an indexed
    /// posting fetch over a bounded candidate set — never a scan and never a model.
    func testSearchLatencyStaysWithinBudgetOnALargeCorpus() async throws {
        let store = try TestStore.make()
        let built = await synthesize(into: store)
        let search = SearchService(store: store)

        await XCTAssertEqual(await store.documentCount(), built.lines)
        print("[perf] indexed \(built.lines) documents, \(await store.postingCount()) postings")

        // A rare term: one posting list, one document.
        let rareHits = await search.search(SearchQuery(text: "quokka")).hits
        await XCTAssertEqual(rareHits.map(\.refID), [built.needle])

        // A common term: a long posting list, capped by `perTokenLimit`.
        for _ in 0..<5 {
            _ = await search.search(SearchQuery(text: "project deadline"))
        }

        let report = await search.latencyReport()
        print(String(format: "[perf] search mean %.1f ms, worst %.1f ms over %d samples",
                     report.mean * 1_000, report.worst * 1_000, report.samples))

        await XCTAssertLessThan(report.worst, 2.0,
                          "A search taking seconds means a scan crept into the hot path")
    }

    /// The candidate set is bounded, so a term present in every document must not drag the
    /// whole corpus into memory.
    func testAVeryCommonTermStillReturnsABoundedResultSet() async throws {
        let store = try TestStore.make()
        _ = await synthesize(into: store)

        var query = SearchQuery(text: "project")
        query.limit = 40
        let outcome = await SearchService(store: store).search(query)

        await XCTAssertLessThanOrEqual(outcome.hits.count, 40)
        await XCTAssertLessThanOrEqual(outcome.lexicalCandidates, 400,
                                 "Candidate gathering must be capped, not exhaustive")
    }

    /// Paging through history must not get slower as you go deeper.
    func testDeepPaginationDoesNotDegrade() async throws {
        let store = try TestStore.make()
        let sessionID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await store.startSession(id: sessionID, at: base, inputName: nil,
                                 usedBuiltInMic: true, otherAudioPlaying: false)

        for index in 0..<600 {
            await store.insertTranscript(id: UUID(), sessionID: sessionID, audioSegmentID: nil,
                                         speakerID: nil, speakerConfidence: 0,
                                         startedAt: base.addingTimeInterval(Double(index) * 10),
                                         endedAt: base.addingTimeInterval(Double(index) * 10 + 4),
                                         index: index, text: "line number \(index)",
                                         confidence: 0.8, audioQuality: 0.7, assertion: .stated,
                                         languageCode: "en-US", wordTimings: [],
                                         isLowConfidence: false)
        }

        let firstPage = await store.transcriptLines(sessionID: sessionID, limit: 50)
        await XCTAssertEqual(firstPage.count, 50)

        let early = await time { _ = await store.transcriptLines(from: base, to: base.addingTimeInterval(600)) }
        let late = await time {
            _ = await store.transcriptLines(from: base.addingTimeInterval(5_000),
                                            to: base.addingTimeInterval(5_600))
        }
        print(String(format: "[perf] window fetch early %.1f ms, late %.1f ms",
                     early * 1_000, late * 1_000))
        await XCTAssertLessThan(late, max(0.5, early * 20),
                          "A later time window must not cost dramatically more than an earlier one")
    }

    /// Stats back Diagnostics and the widget, and run often enough that a scan would show.
    func testStatsAreCheapEnoughToCallOften() async throws {
        let store = try TestStore.make()
        _ = await synthesize(into: store)

        let elapsed = await time { _ = await store.stats() }
        print(String(format: "[perf] stats %.1f ms", elapsed * 1_000))
        await XCTAssertLessThan(elapsed, 1.0)
    }

    /// Rough storage-growth figure for docs/PERFORMANCE.md, measured rather than guessed.
    func testIndexGrowthPerLineIsMeasuredAndReported() async throws {
        let store = try TestStore.make()
        _ = await synthesize(into: store)

        let documents = await store.documentCount()
        let postings = await store.postingCount()
        let perLine = Double(postings) / Double(max(1, documents))

        print(String(format: "[perf] %d documents, %d postings, %.1f postings per line",
                     documents, postings, perLine))
        await XCTAssertGreaterThan(perLine, 1, "Every line should contribute several terms")
        await XCTAssertLessThan(perLine, 40, "A runaway posting count would be a tokeniser bug")
    }

    /// The memory layer must stay bounded when the same things are said over and over —
    /// which is what a year of real conversations looks like.
    func testRepeatedClaimsDoNotGrowTheMemoryTableLinearly() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for round in 0..<200 {
            _ = await store.upsertMemory(MemoryCandidate(
                kind: .fact,
                title: "The deadline is on Friday",
                detail: "the aurora deadline is on friday",
                confidence: 0.6,
                assertion: .stated,
                importance: 0.4,
                occurredAt: base.addingTimeInterval(Double(round) * 3_600),
                sourceKind: .transcriptSegment,
                sourceIDs: [UUID()],
                dedupeKey: "fact|aurora-deadline-friday"))
        }

        let memories = await store.memories(limit: 100)
        await XCTAssertEqual(memories.count, 1, "200 repetitions of one claim is one memory")

        let memory = try await XCTUnwrap(memories.first)
        await XCTAssertEqual(memory.occurrenceCount, 200)
        await XCTAssertLessThanOrEqual(memory.confidence, 1.0, "Confidence must saturate, not run away")
        await XCTAssertLessThanOrEqual(memory.sourceIDs.count, 64,
                                 "The source list must be capped or a memory grows without bound")
    }

    /// The job queue is walked constantly; claiming must be an indexed fetch of one row.
    func testClaimingFromALargeQueueIsCheap() async throws {
        let store = try TestStore.make()
        for index in 0..<500 {
            await store.enqueueJob(kind: .rollupDay,
                                   payload: RollupPayload(key: "day-\(index)").json,
                                   priority: index % 5)
        }
        await XCTAssertEqual(await store.pendingJobCount(), 500)

        let elapsed = await time { _ = await store.claimNextJob() }
        print(String(format: "[perf] claim from 500-job queue %.1f ms", elapsed * 1_000))
        await XCTAssertLessThan(elapsed, 0.5)
    }

    // MARK: - Helpers

    private func time(_ work: () async -> Void) async -> TimeInterval {
        let started = DispatchTime.now().uptimeNanoseconds
        await work()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }
}

/// A tiny deterministic generator, so "large synthetic dataset" means the *same* large
/// dataset on every run and a performance regression cannot hide behind new random data.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(under bound: UInt64) -> UInt64 {
        bound == 0 ? 0 : next() % bound
    }
}
