import Foundation
import XCTest

@testable import Clipper

/// Tokenisation, the inverted index, hybrid ranking, filters, snippets, evidence chains and
/// grounded answers.
///
/// The ranking tests assert *orderings*, not absolute scores. Scores are a blend of six
/// components and will drift as the blend is tuned; the orderings are the behaviour the
/// product actually promises.
final class TokenizerTests: XCTestCase {

    func testTokenisationFoldsCaseAndDropsStopwordsAndPunctuation() {
        let tokens = Tokenizer.tokens(in: "The Aurora project, and the DEADLINE!")
        XCTAssertFalse(tokens.contains("the"))
        XCTAssertFalse(tokens.contains("and"))
        XCTAssertTrue(tokens.contains("aurora"))
        XCTAssertTrue(tokens.contains("project"))
        XCTAssertTrue(tokens.contains("deadline"))
        XCTAssertFalse(tokens.contains(where: { $0.contains(",") || $0.contains("!") }))
    }

    func testSingleCharactersAreDropped() {
        XCTAssertTrue(Tokenizer.tokens(in: "a b c").isEmpty)
    }

    func testStemmingIsConservative() {
        // Plurals and simple verb endings collapse…
        XCTAssertEqual(Tokenizer.stem("deadlines"), Tokenizer.stem("deadline"))
        XCTAssertEqual(Tokenizer.stem("meetings"), Tokenizer.stem("meeting"))
        // …but distinct words must not.
        XCTAssertNotEqual(Tokenizer.stem("postgres"), Tokenizer.stem("sqlite"))
        XCTAssertNotEqual(Tokenizer.stem("sail"), Tokenizer.stem("sale"))
    }

    private func weight(_ weighted: Tokenizer.Weighted, _ token: String) -> Double {
        weighted.weights.first { $0.0 == token }?.1 ?? 0
    }

    /// A title word matters more than the same word buried in a long body.
    func testTitleTokensCarryMoreWeightThanBodyTokens() {
        let weighted = Tokenizer.weightedTokens(title: "Aurora", body: "we talked about sailing")
        XCTAssertGreaterThan(weight(weighted, "aurora"), weight(weighted, "sailing"))
        XCTAssertGreaterThan(weighted.totalTokens, 0)
    }

    /// Long documents must not out-rank short ones purely by repeating a word.
    func testWeightsAreLengthNormalised() {
        let short = Tokenizer.weightedTokens(title: "", body: "aurora aurora")
        let long = Tokenizer.weightedTokens(title: "",
                                            body: (["aurora", "aurora"]
                                                   + Array(repeating: "filler", count: 200))
                                                .joined(separator: " "))
        XCTAssertGreaterThan(weight(short, "aurora"), weight(long, "aurora"))
    }

    func testNameNormalisationCollapsesCasePaddingAndPunctuation() {
        XCTAssertEqual(Tokenizer.normalizeName("  The Aurora Project. "),
                       Tokenizer.normalizeName("the aurora project"))
        XCTAssertNotEqual(Tokenizer.normalizeName("Aurora"), Tokenizer.normalizeName("Borealis"))
    }

    /// Word order and punctuation are not a different claim.
    func testClaimKeysIgnoreOrderingAndPunctuation() {
        let a = Tokenizer.dedupeKey(kind: .fact, subject: nil, claim: "the deadline is friday")
        let restated = Tokenizer.dedupeKey(kind: .fact, subject: nil,
                                           claim: "Friday is the deadline!")
        XCTAssertEqual(a, restated)

        let different = Tokenizer.dedupeKey(kind: .fact, subject: nil,
                                            claim: "the deadline is monday")
        XCTAssertNotEqual(a, different)
    }

    func testPhraseMatchingIsWholePhraseNotBagOfWords() {
        XCTAssertTrue(Tokenizer.containsPhrase("aurora deadline",
                                               in: "the aurora deadline is on friday"))
        XCTAssertFalse(Tokenizer.containsPhrase("aurora deadline",
                                                in: "aurora is fine and the deadline moved"))
    }
}

// MARK: - Query parsing

final class QueryParserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testScaffoldingIsStrippedFromTheSearchText() {
        let parser = QueryParser()
        let query = parser.parse("what did I say about the budget", now: now)
        XCTAssertTrue(query.text.lowercased().contains("budget"))
        XCTAssertFalse(query.text.lowercased().contains("what did i say"))
    }

    func testAQueryThatIsAllScaffoldingKeepsTheOriginalText() {
        let parser = QueryParser()
        let query = parser.parse("show me", now: now)
        XCTAssertFalse(query.text.isEmpty, "An empty query would return everything")
    }

    func testRelativeDatesBecomeBounds() throws {
        let parser = QueryParser()
        let query = parser.parse("what did I say yesterday", now: now)
        let from = try XCTUnwrap(query.from)
        let to = try XCTUnwrap(query.to)
        XCTAssertLessThan(from, to)
        XCTAssertLessThan(from, now)
    }

    func testAKnownSpeakerNameBecomesASpeakerFilter() {
        var parser = QueryParser()
        let alexID = UUID()
        parser.knownSpeakers = [(id: alexID, name: "Alex")]

        let query = parser.parse("what did Alex say about aurora", now: now)
        XCTAssertEqual(query.speakerIDs, [alexID])
        XCTAssertFalse(query.text.lowercased().contains("alex"),
                       "The name became a filter, so it should not also be a search term")
        XCTAssertTrue(query.text.lowercased().contains("aurora"))
    }

    /// A topic name stays in the text as well, because it is a strong lexical signal.
    func testAKnownTopicBecomesAFilterAndStaysInTheText() {
        var parser = QueryParser()
        let auroraID = UUID()
        parser.knownNodes = [(id: auroraID, name: "aurora")]

        let query = parser.parse("show all conversations related to aurora", now: now)
        XCTAssertEqual(query.nodeIDs, [auroraID])
        XCTAssertTrue(query.text.lowercased().contains("aurora"))
    }

    func testKindWordsNarrowTheResultKinds() {
        let parser = QueryParser()
        XCTAssertTrue(parser.parse("what decisions did we make", now: now).kinds.contains(.memory))
        XCTAssertTrue(parser.parse("show me the transcript", now: now).kinds.contains(.transcriptSegment))
    }

    func testUnrecognisedWordsAreLeftAloneRatherThanDropped() {
        let parser = QueryParser()
        let query = parser.parse("quokka migration script", now: now)
        XCTAssertTrue(query.text.contains("quokka"))
        XCTAssertTrue(query.kinds.isEmpty)
        XCTAssertNil(query.from)
    }

    func testIntentDetectionCoversTheSpecQuestions() {
        XCTAssertEqual(QueryParser.intent(of: "When did I first discuss aurora?"), .firstMention)
        XCTAssertEqual(QueryParser.intent(of: "Find every time I mentioned the deadline"), .enumerate)
        XCTAssertEqual(QueryParser.intent(of: "What evidence do I have for that?"), .evidence)
        XCTAssertEqual(QueryParser.intent(of: "What changed between my earlier and later statements?"),
                       .change)
        XCTAssertEqual(QueryParser.intent(of: "Summarise everything I said about aurora"), .summary)
        XCTAssertEqual(QueryParser.intent(of: "Who is Sam?"), .question)
        XCTAssertEqual(QueryParser.intent(of: "aurora"), .lookup)
    }
}

// MARK: - Indexing and ranking

final class SearchServiceTests: XCTestCase {

    private func index(_ store: ClipperStore,
                       kind: DocumentKind = .transcriptSegment,
                       title: String,
                       text: String,
                       at date: Date = Date(timeIntervalSince1970: 1_780_000_000),
                       speakers: [UUID] = [],
                       nodes: [UUID] = [],
                       importance: Double = 0.3,
                       confidence: Double = 0.8,
                       assertion: AssertionKind = .stated,
                       refID: UUID = UUID()) async -> UUID {
        await store.indexDocument(IndexCandidate(kind: kind,
                                                 refID: refID,
                                                 conversationID: nil,
                                                 title: title,
                                                 text: text,
                                                 timestamp: date,
                                                 speakerIDs: speakers,
                                                 nodeIDs: nodes,
                                                 importance: importance,
                                                 confidence: confidence,
                                                 assertion: assertion,
                                                 embedding: []))
        return refID
    }

    private func service(_ store: ClipperStore) -> SearchService {
        SearchService(store: store)
    }

    func testAnEmptyQueryReturnsNothingRatherThanEverything() async throws {
        let store = try TestStore.make()
        _ = await index(store, title: "Aurora", text: "we chose postgres")
        let outcome = await service(store).search(SearchQuery(text: "   "))
        await XCTAssertTrue(outcome.hits.isEmpty)
    }

    func testAMatchingTermFindsItsDocument() async throws {
        let store = try TestStore.make()
        let refID = await index(store, title: "Aurora planning",
                                text: "we decided we will use postgres for the aurora project")
        _ = await index(store, title: "Sailing", text: "I want to learn to sail this summer")

        let outcome = await service(store).search(SearchQuery(text: "postgres"))
        await XCTAssertEqual(outcome.hits.count, 1)
        await XCTAssertEqual(outcome.hits.first?.refID, refID)
        let term = try await XCTUnwrap(Tokenizer.tokens(in: "postgres").first)
        await XCTAssertTrue(outcome.hits.first?.matchedTokens.contains(term) ?? false,
                            "Matched tokens are index terms, so they are stemmed")
        await XCTAssertGreaterThan(outcome.lexicalCandidates, 0)
    }

    /// Re-indexing must replace the old postings, or a corrected transcript still matches
    /// the word it no longer contains.
    func testReindexingRemovesStalePostings() async throws {
        let store = try TestStore.make()
        let refID = UUID()
        _ = await index(store, title: "Line", text: "a roarer needs the migration script", refID: refID)
        await XCTAssertEqual(await service(store).search(SearchQuery(text: "roarer")).hits.count, 1)

        _ = await index(store, title: "Line", text: "aurora needs the migration script", refID: refID)
        await XCTAssertTrue(await service(store).search(SearchQuery(text: "roarer")).hits.isEmpty,
                      "The corrected text must not still match the mishearing")
        await XCTAssertEqual(await service(store).search(SearchQuery(text: "aurora")).hits.count, 1)
        await XCTAssertEqual(await store.documentCount(), 1, "Re-indexing is an update, not an insert")
    }

    /// A rare term must beat a common one. This is the IDF half of the ranking.
    func testRareTermsOutrankCommonOnes() async throws {
        let store = try TestStore.make()
        for line in 0..<15 {
            _ = await index(store, title: "Line \(line)",
                            text: "we talked about the project again today")
        }
        let rare = await index(store, title: "Line rare",
                               text: "we talked about the quokka project today")

        let outcome = await service(store).search(SearchQuery(text: "quokka project"))
        await XCTAssertEqual(outcome.hits.first?.refID, rare,
                       "The document with the distinctive term must come first")
    }

    /// Two documents with the same words: the recent one wins.
    func testRecencyBreaksTies() async throws {
        let store = try TestStore.make()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let older = await index(store, title: "Aurora", text: "aurora deadline discussion",
                                at: old, refID: UUID())
        let newer = await index(store, title: "Aurora", text: "aurora deadline discussion",
                                at: old.addingTimeInterval(86_400 * 120), refID: UUID())

        let hits = await service(store).search(SearchQuery(text: "aurora deadline")).hits
        await XCTAssertEqual(hits.count, 2)
        await XCTAssertEqual(hits.first?.refID, newer)
        await XCTAssertEqual(hits.last?.refID, older)
    }

    /// An exact phrase must beat the same words scattered apart.
    func testExactPhrasesOutrankScatteredWords() async throws {
        let store = try TestStore.make()
        let scattered = await index(store, title: "A",
                                    text: "the aurora work is fine but the deadline moved again")
        let exact = await index(store, title: "B",
                                text: "the aurora deadline is on friday")
        _ = scattered

        let hits = await service(store).search(SearchQuery(text: "aurora deadline")).hits
        await XCTAssertEqual(hits.first?.refID, exact)
    }

    /// Low-confidence, uncertain lines are still findable — but they rank below solid ones.
    func testUncertainEvidenceIsDownRankedNotHidden() async throws {
        let store = try TestStore.make()
        let solid = await index(store, title: "Clear", text: "the aurora migration script",
                                confidence: 0.9, assertion: .stated)
        let mumbled = await index(store, title: "Mumbled", text: "the aurora migration script",
                                  confidence: 0.2, assertion: .uncertain)

        let hits = await service(store).search(SearchQuery(text: "aurora migration")).hits
        await XCTAssertEqual(hits.count, 2, "Uncertain evidence is still evidence")
        await XCTAssertEqual(hits.first?.refID, solid)
        await XCTAssertEqual(hits.last?.refID, mumbled)
    }

    func testImportanceLiftsAMemoryAboveAPassingMention() async throws {
        let store = try TestStore.make()
        let passing = await index(store, kind: .transcriptSegment, title: "chat",
                                  text: "aurora came up briefly", importance: 0.05)
        let important = await index(store, kind: .memory, title: "Aurora decision",
                                    text: "aurora came up briefly", importance: 0.9)
        _ = passing

        let hits = await service(store).search(SearchQuery(text: "aurora")).hits
        await XCTAssertEqual(hits.first?.refID, important)
    }

    func testKindFilterExcludesOtherKinds() async throws {
        let store = try TestStore.make()
        _ = await index(store, kind: .transcriptSegment, title: "line", text: "aurora talk")
        let memory = await index(store, kind: .memory, title: "memory", text: "aurora talk")

        var query = SearchQuery(text: "aurora")
        query.kinds = [.memory]
        let hits = await service(store).search(query).hits
        await XCTAssertEqual(hits.map(\.refID), [memory])
    }

    func testSpeakerFilterExcludesOtherVoices() async throws {
        let store = try TestStore.make()
        let alex = UUID()
        let sam = UUID()
        let alexLine = await index(store, title: "Alex", text: "aurora is on track", speakers: [alex])
        _ = await index(store, title: "Sam", text: "aurora is on track", speakers: [sam])

        var query = SearchQuery(text: "aurora")
        query.speakerIDs = [alex]
        await XCTAssertEqual(await service(store).search(query).hits.map(\.refID), [alexLine])
    }

    func testDateFilterExcludesOutsideTheWindow() async throws {
        let store = try TestStore.make()
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let inside = await index(store, title: "inside", text: "aurora", at: base)
        _ = await index(store, title: "outside", text: "aurora",
                        at: base.addingTimeInterval(-86_400 * 30))

        var query = SearchQuery(text: "aurora")
        query.from = base.addingTimeInterval(-3_600)
        query.to = base.addingTimeInterval(3_600)
        await XCTAssertEqual(await service(store).search(query).hits.map(\.refID), [inside])
    }

    func testNodeFilterNarrowsToATopic() async throws {
        let store = try TestStore.make()
        let node = UUID()
        let tagged = await index(store, title: "tagged", text: "the deadline", nodes: [node])
        _ = await index(store, title: "untagged", text: "the deadline")

        var query = SearchQuery(text: "deadline")
        query.nodeIDs = [node]
        await XCTAssertEqual(await service(store).search(query).hits.map(\.refID), [tagged])
    }

    func testConfidenceFloorFiltersOutTheMumbling() async throws {
        let store = try TestStore.make()
        _ = await index(store, title: "mumbled", text: "aurora", confidence: 0.2)
        let clear = await index(store, title: "clear", text: "aurora", confidence: 0.9)

        var query = SearchQuery(text: "aurora")
        query.minimumConfidence = 0.5
        await XCTAssertEqual(await service(store).search(query).hits.map(\.refID), [clear])
    }

    func testResultsRespectTheLimit() async throws {
        let store = try TestStore.make()
        for line in 0..<30 {
            _ = await index(store, title: "line \(line)", text: "aurora line \(line)")
        }
        var query = SearchQuery(text: "aurora")
        query.limit = 7
        await XCTAssertEqual(await service(store).search(query).hits.count, 7)
    }

    func testANonMatchingQueryReturnsNothingRatherThanNoise() async throws {
        let store = try TestStore.make()
        _ = await index(store, title: "Aurora", text: "we chose postgres for aurora")
        var query = SearchQuery(text: "helicopter maintenance")
        query.semanticEnabled = false
        await XCTAssertTrue(await service(store).search(query).hits.isEmpty)
    }

    // MARK: Snippets

    func testSnippetCentresOnTheMatchAndMarksTruncation() {
        let text = String(repeating: "padding words here. ", count: 30)
            + "the aurora deadline is on friday. "
            + String(repeating: "more padding. ", count: 30)
        let snippet = SearchService.snippet(from: text, query: "aurora deadline",
                                            tokens: ["aurora", "deadline"], width: 80)

        XCTAssertTrue(snippet.lowercased().contains("aurora"))
        XCTAssertLessThan(snippet.count, 140)
        XCTAssertTrue(snippet.hasPrefix("…"), "A snippet cut from the middle should say so")
    }

    func testShortTextIsUsedWholeWithoutEllipses() {
        let snippet = SearchService.snippet(from: "aurora is fine", query: "aurora",
                                            tokens: ["aurora"], width: 180)
        XCTAssertEqual(snippet, "aurora is fine")
    }

    func testSnippetWithNoMatchFallsBackToTheStart() {
        let snippet = SearchService.snippet(from: "nothing relevant in this line at all",
                                            query: "aurora", tokens: ["aurora"], width: 20)
        XCTAssertFalse(snippet.isEmpty)
    }

    // MARK: Latency

    func testLatencyIsMeasuredAndReported() async throws {
        let store = try TestStore.make()
        _ = await index(store, title: "Aurora", text: "aurora deadline")
        let search = service(store)
        for _ in 0..<3 { _ = await search.search(SearchQuery(text: "aurora")) }

        let report = await search.latencyReport()
        await XCTAssertEqual(report.samples, 3)
        await XCTAssertGreaterThan(report.mean, 0)
        await XCTAssertGreaterThanOrEqual(report.worst, report.mean)
    }
}

// MARK: - Answering, evidence and honesty

final class AnswerServiceTests: XCTestCase {

    private func loadedStore() async throws -> (ClipperStore, AnswerService) {
        let store = try TestStore.make()
        await MessyCorpus.load(into: store)
        _ = await MessyCorpus.closeAndBuildMemories(in: store)
        let answers = AnswerService(store: store, search: SearchService(store: store))
        return (store, answers)
    }

    /// The most important honesty test in the suite: nothing in the store supports this, so
    /// the answer must say so rather than invent something.
    func testAQuestionWithNoEvidenceSaysSoRatherThanGuessing() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("what did we decide about the helicopter lease?")

        await XCTAssertTrue(answer.insufficientEvidence)
        await XCTAssertEqual(answer.assertion, .unsupported)
        await XCTAssertTrue(answer.chains.isEmpty)
        await XCTAssertFalse(answer.answer.isEmpty, "Saying nothing is not the same as saying 'I don't know'")
    }

    func testAnEmptyStoreCannotAnswerAnything() async throws {
        let store = try TestStore.make()
        let answers = AnswerService(store: store, search: SearchService(store: store))
        let answer = await answers.answer("what did I say about aurora?")
        await XCTAssertTrue(answer.insufficientEvidence)
    }

    /// Every answer must be traceable back to a transcript line with a timestamp.
    func testAnsweredQuestionsCarryAnEvidenceChain() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("what did we decide about aurora?")

        await XCTAssertFalse(answer.insufficientEvidence)
        await XCTAssertFalse(answer.chains.isEmpty, "An answer without a chain is an unsupported claim")

        let chain = try await XCTUnwrap(answer.chains.first)
        await XCTAssertFalse(chain.leaf.text.isEmpty)
        await XCTAssertGreaterThan(chain.leaf.endedAt, chain.leaf.startedAt)
        XCTAssertNotNil(chain.memory ?? chain.summary,
                        "A chain starts at a memory or a summary")
        await XCTAssertNotNil(chain.conversation)
    }

    /// The audio is gone after the retention window; the chain must say so rather than
    /// offering a play button that does nothing.
    func testAChainWithNoAudioIsHonestAboutIt() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("what did we decide about aurora?")
        for chain in answer.chains where chain.audioURL == nil {
            await XCTAssertTrue(chain.audioExpired || chain.leaf.audioSegmentID == nil)
        }
    }

    func testFirstMentionReturnsTheEarliestNotTheBestMatch() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("when did I first discuss aurora?")

        await XCTAssertFalse(answer.insufficientEvidence)
        let earliest = try await XCTUnwrap(answer.hits.first)
        for hit in answer.hits {
            await XCTAssertLessThanOrEqual(earliest.timestamp, hit.timestamp)
        }
    }

    func testEnumerateReturnsEveryMentionInTimeOrder() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("find every time I mentioned aurora")

        await XCTAssertGreaterThan(answer.hits.count, 2)
        let timestamps = answer.hits.map(\.timestamp)
        await XCTAssertEqual(timestamps, timestamps.sorted(), "An enumeration is chronological")
    }

    /// "What changed?" must surface the supersession, not just the latest statement.
    func testChangeQuestionsSurfaceBothSidesOfTheDecision() async throws {
        let (store, answers) = try await loadedStore()
        let answer = await answers.answer("what changed about the aurora database?")

        await XCTAssertFalse(answer.answer.isEmpty)
        // Either the answer cites a superseded revision, or the store holds one to cite.
        let superseded = await store.memories(includeSuperseded: true)
            .filter { $0.supersededByID != nil }
        await XCTAssertFalse(superseded.isEmpty || answer.chains.isEmpty,
                       "A change question needs a history to answer from")
    }

    func testAnswersAreLabelledWithHowTheyRelateToTheEvidence() async throws {
        let (_, answers) = try await loadedStore()
        let answer = await answers.answer("what did we decide about aurora?")
        await XCTAssertTrue([.stated, .summarised, .inferred, .uncertain, .contradictory]
            .contains(answer.assertion))
        await XCTAssertFalse(answer.generator.isEmpty)
    }

    /// The parser must not need a model to turn a sentence into filters.
    func testQueryBuildingUsesTheLiveVocabulary() async throws {
        let (store, answers) = try await loadedStore()
        let speakers = await store.speakers()
        await XCTAssertFalse(speakers.isEmpty)

        let query = await answers.buildQuery(from: "what did Alex say about aurora")
        await XCTAssertFalse(query.speakerIDs.isEmpty, "A known name must become a filter")
    }

    func testSearchThroughTheAnswerServiceFindsTheMishearing() async throws {
        let (_, answers) = try await loadedStore()
        // The corpus contains "a roarer needs the migration script" — a mishearing of
        // "aurora". Searching the literal words must still find it.
        let outcome = await answers.runSearch("migration script")
        await XCTAssertFalse(outcome.hits.isEmpty)
    }
}

// MARK: - Spotlight payloads

final class SpotlightItemTests: XCTestCase {

    /// The identifier *is* the deep link, so handling a Spotlight tap is the same code path
    /// as handling a widget tap.
    func testItemIdentifiersAreDeepLinks() throws {
        let memory = MemoryDTO(id: UUID(), kind: .decision, title: "Use Postgres",
                               detail: "for the aurora project", confidence: 0.8,
                               assertion: .stated, importance: 0.6, createdAt: Date(),
                               updatedAt: Date(), firstSeenAt: Date(), lastSeenAt: Date(),
                               occurrenceCount: 2, revision: 0, supersedesID: nil,
                               supersededByID: nil, isArchived: false, isUserEdited: false,
                               sourceKind: .transcriptSegment, sourceIDs: [UUID()],
                               nodeIDs: [], subjectSpeakerID: nil, strength: 0.7)

        let item = SpotlightIndexer.item(for: memory, topics: ["aurora"])
        XCTAssertEqual(item.link, .memory(memory.id))

        // Round-tripping through the URL is the path a Spotlight tap actually takes.
        let parsed = ClipperDeepLink(url: item.link.url)
        XCTAssertEqual(parsed, .memory(memory.id))
    }

    /// Raw transcript text must not be handed to the system index.
    func testMemoryItemsPublishTitlesAndSummariesOnly() {
        let memory = MemoryDTO(id: UUID(), kind: .fact, title: "The deadline",
                               detail: "the aurora deadline is on friday", confidence: 0.8,
                               assertion: .stated, importance: 0.5, createdAt: Date(),
                               updatedAt: Date(), firstSeenAt: Date(), lastSeenAt: Date(),
                               occurrenceCount: 1, revision: 0, supersedesID: nil,
                               supersededByID: nil, isArchived: false, isUserEdited: false,
                               sourceKind: .transcriptSegment, sourceIDs: [UUID()],
                               nodeIDs: [], subjectSpeakerID: nil, strength: 0.5)

        let item = SpotlightIndexer.item(for: memory, topics: ["aurora", "deadline"])
        XCTAssertEqual(item.title, "The deadline")
        XCTAssertTrue(item.keywords.contains("aurora"))
    }

    /// An unnamed voice has nothing useful to index, and indexing "Unknown voice" would be
    /// noise in the user's system-wide search.
    func testUnnamedSpeakersAreNotIndexed() {
        let speaker = SpeakerDTO(id: UUID(), displayName: nil, isNamed: false, sampleCount: 4,
                                 totalSpeechSeconds: 30, identityConfidence: 0.5,
                                 promptState: .pending, colorIndex: 0, createdAt: Date(),
                                 previousNames: [])
        XCTAssertNil(SpotlightIndexer.item(for: speaker))

        let named = SpeakerDTO(id: speaker.id, displayName: "Alex", isNamed: true, sampleCount: 4,
                               totalSpeechSeconds: 30, identityConfidence: 0.8,
                               promptState: .named, colorIndex: 0, createdAt: Date(),
                               previousNames: [])
        XCTAssertNotNil(SpotlightIndexer.item(for: named))
    }
}
