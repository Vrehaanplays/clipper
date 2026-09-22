import Foundation
import XCTest

@testable import Clipper

/// The surfaces outside the app window: deep links, the widget snapshot, the Live Activity
/// content state, and the phase vocabulary all three share.
///
/// None of these tests place a widget or start a Live Activity — iOS controls both, and a
/// unit test cannot. What they do test is every part that is ours: the payloads, the
/// encoding, the staleness rules and the phase mapping. Those are where the bugs live.
final class DeepLinkTests: XCTestCase {

    private let identifier = UUID()

    func testEveryLinkRoundTripsThroughItsURL() {
        let links: [ClipperDeepLink] = [
            .listen, .today, .unresolved,
            .search(nil), .search("aurora deadline"),
            .conversation(identifier), .memory(identifier),
            .speaker(identifier), .node(identifier),
        ]
        for link in links {
            XCTAssertEqual(ClipperDeepLink(url: link.url), link, "\(link) did not round-trip")
        }
    }

    func testURLsUseTheClipperScheme() {
        XCTAssertEqual(ClipperDeepLink.memory(identifier).url.scheme, "clipper")
        XCTAssertEqual(ClipperDeepLink.scheme, "clipper")
    }

    func testSearchQueriesSurviveSpacesAndPunctuation() {
        let link = ClipperDeepLink.search("what did Alex say about aurora?")
        guard case .search(let parsed) = try? XCTUnwrap(ClipperDeepLink(url: link.url)) else {
            return XCTFail("A search link must parse back as a search link")
        }
        XCTAssertEqual(parsed, "what did Alex say about aurora?")
    }

    func testForeignAndMalformedURLsAreRejected() {
        for raw in ["https://example.com/memory/123",
                    "clipper://memory/not-a-uuid",
                    "clipper://nonsense",
                    "clipper://conversation"] {
            let url = URL(string: raw)
            XCTAssertNil(url.flatMap(ClipperDeepLink.init(url:)), "\(raw) should not parse")
        }
    }

    /// Spotlight identifiers *are* deep links, so a tap is a URL parse rather than a lookup
    /// table that can drift.
    func testSpotlightIdentifiersAreValidDeepLinks() {
        let node = GraphNodeDTO(id: identifier, kind: .project, name: "Aurora", mentionCount: 4,
                                importance: 0.6, lastMentionedAt: Date(), refID: nil, summaryID: nil)
        let item = SpotlightIndexer.item(for: node)
        XCTAssertEqual(ClipperDeepLink(url: item.link.url), .node(identifier))
    }
}

// MARK: - Phases

final class ClipperPhaseTests: XCTestCase {

    /// The phase vocabulary is the honesty contract: the app must never claim to be
    /// recording when iOS has suspended it.
    func testOnlyGenuinelyCapturingPhasesReportCapture() {
        let capturing: [ClipperPhase] = [.listening, .speech]
        let notCapturing: [ClipperPhase] = [.inactive, .starting, .paused, .interrupted,
                                            .recovering, .permissionDenied, .failed]

        for phase in capturing {
            XCTAssertTrue(phase.isCapturingAudio, "\(phase) should report capture")
        }
        for phase in notCapturing {
            XCTAssertFalse(phase.isCapturingAudio,
                           "\(phase) must not claim the microphone is live")
        }
    }

    /// A session can be active while not capturing — paused, interrupted or recovering.
    /// Both flags are needed, and they are not the same flag.
    func testInterruptedIsActiveButNotCapturing() {
        XCTAssertTrue(ClipperPhase.interrupted.isSessionActive)
        XCTAssertFalse(ClipperPhase.interrupted.isCapturingAudio)

        XCTAssertTrue(ClipperPhase.paused.isSessionActive)
        XCTAssertFalse(ClipperPhase.paused.isCapturingAudio)

        XCTAssertFalse(ClipperPhase.inactive.isSessionActive)
        XCTAssertFalse(ClipperPhase.permissionDenied.isSessionActive)
    }

    func testEveryPhaseHasUserFacingText() {
        for phase in ClipperPhase.allCases {
            XCTAssertFalse(phase.title.isEmpty, "\(phase) has no title")
            XCTAssertFalse(phase.compactTitle.isEmpty, "\(phase) has no compact title")
            XCTAssertFalse(phase.symbolName.isEmpty, "\(phase) has no symbol")
            XCTAssertLessThanOrEqual(phase.compactTitle.count, 12,
                                     "\(phase) will not fit the Dynamic Island")
        }
    }

    func testPhasesSurviveCodingSoTheWidgetSeesWhatTheAppWrote() throws {
        for phase in ClipperPhase.allCases {
            let data = try JSONEncoder().encode(phase)
            XCTAssertEqual(try JSONDecoder().decode(ClipperPhase.self, from: data), phase)
        }
    }
}

// MARK: - Widget snapshot

final class SnapshotTests: XCTestCase {

    private func encoded(_ snapshot: ClipperSnapshot) throws -> ClipperSnapshot {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = SnapshotDateCoding.encoding
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SnapshotDateCoding.decoding
        return try decoder.decode(ClipperSnapshot.self, from: try encoder.encode(snapshot))
    }

    func testSnapshotsRoundTripThroughTheSharedFileFormat() throws {
        let snapshot = ClipperSnapshot(phase: .speech,
                                       sessionStartedAt: Date(timeIntervalSince1970: 1_780_000_000),
                                       speechSeconds: 754,
                                       pendingJobs: 3,
                                       isProcessing: true,
                                       lowConfidence: true,
                                       recentMemory: "Use SQLite for aurora",
                                       recentSummary: "The team changed database",
                                       memoryCount: 42)
        let decoded = try encoded(snapshot)
        // The wire format is millisecond-precise, which is what the staleness check needs,
        // so the timestamps are compared to that precision rather than bit-for-bit.
        XCTAssertEqual(decoded.phase, snapshot.phase)
        XCTAssertEqual(decoded.speechSeconds, snapshot.speechSeconds)
        XCTAssertEqual(decoded.pendingJobs, snapshot.pendingJobs)
        XCTAssertEqual(decoded.isProcessing, snapshot.isProcessing)
        XCTAssertEqual(decoded.lowConfidence, snapshot.lowConfidence)
        XCTAssertEqual(decoded.recentMemory, snapshot.recentMemory)
        XCTAssertEqual(decoded.recentSummary, snapshot.recentSummary)
        XCTAssertEqual(decoded.memoryCount, snapshot.memoryCount)
        XCTAssertEqual(try XCTUnwrap(decoded.sessionStartedAt).timeIntervalSince1970,
                       try XCTUnwrap(snapshot.sessionStartedAt).timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970,
                       snapshot.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(decoded.speechLabel, "12m")
    }

    func testNilFieldsSurviveEncoding() throws {
        let decoded = try encoded(ClipperSnapshot())
        XCTAssertNil(decoded.sessionStartedAt)
        XCTAssertNil(decoded.recentMemory)
        XCTAssertEqual(decoded.phase, .inactive)
    }

    /// The app was killed mid-session and never got to write `inactive`. The widget must
    /// notice rather than show "Recording" forever.
    func testAnOldActiveSnapshotIsStale() {
        let stale = ClipperSnapshot(phase: .listening,
                                    updatedAt: Date().addingTimeInterval(-ClipperSnapshot.staleAfter - 60))
        XCTAssertTrue(stale.isStale)

        let fresh = ClipperSnapshot(phase: .listening, updatedAt: Date())
        XCTAssertFalse(fresh.isStale)
    }

    /// An old *inactive* snapshot is not stale — it is simply the truth, unchanged.
    func testAnOldInactiveSnapshotIsNotStale() {
        let old = ClipperSnapshot(phase: .inactive,
                                  updatedAt: Date().addingTimeInterval(-86_400 * 7))
        XCTAssertFalse(old.isStale)
    }

    func testThePlaceholderIsSafeToRenderBeforeAnythingHasHappened() {
        let placeholder = ClipperSnapshot.placeholder
        XCTAssertEqual(placeholder.phase, .inactive)
        XCTAssertFalse(placeholder.isStale)
        XCTAssertNotNil(placeholder.recentMemory)
    }

    /// The whole point of the file: the widget must be able to render without touching the
    /// database. So the snapshot has to carry everything it shows.
    func testSnapshotCarriesEverythingTheWidgetRenders() {
        let snapshot = ClipperSnapshot(phase: .listening,
                                       sessionStartedAt: Date(),
                                       speechSeconds: 90,
                                       pendingJobs: 1,
                                       isProcessing: true,
                                       recentMemory: "a memory",
                                       recentSummary: "a summary",
                                       memoryCount: 7)
        XCTAssertNotNil(snapshot.sessionStartedAt)
        XCTAssertNotNil(snapshot.recentMemory)
        XCTAssertNotNil(snapshot.recentSummary)
        XCTAssertGreaterThan(snapshot.memoryCount, 0)
        XCTAssertFalse(snapshot.speechLabel.isEmpty)
    }

    /// The app group is not provisionable with a free Apple ID. That must be reported
    /// honestly, not papered over.
    func testAppGroupAvailabilityIsReportedTruthfully() {
        let store = AppGroupStore()
        XCTAssertEqual(store.isAvailable, store.containerURL != nil)
        if !store.isAvailable {
            XCTAssertFalse(store.write(ClipperSnapshot()),
                           "A write with no container must report failure, not pretend")
            XCTAssertNil(store.read())
        }
    }
}

// MARK: - Duration formatting

final class ClipperFormatTests: XCTestCase {

    func testClockSwitchesToHoursOnlyWhenItNeedsTo() {
        XCTAssertEqual(ClipperFormat.clock(0), "0:00")
        XCTAssertEqual(ClipperFormat.clock(9), "0:09")
        XCTAssertEqual(ClipperFormat.clock(90), "1:30")
        XCTAssertEqual(ClipperFormat.clock(3_600), "1:00:00")
        XCTAssertEqual(ClipperFormat.clock(3_725), "1:02:05")
    }

    func testNegativeDurationsClampRatherThanRenderingNonsense() {
        XCTAssertEqual(ClipperFormat.clock(-5), "0:00")
        XCTAssertEqual(ClipperFormat.countdown(-5), "00:00")
        XCTAssertEqual(ClipperFormat.compactDuration(-5), "0s")
    }

    func testCompactDurationDropsPrecisionItDoesNotNeed() {
        XCTAssertEqual(ClipperFormat.compactDuration(45), "45s")
        XCTAssertEqual(ClipperFormat.compactDuration(754), "12m")
        XCTAssertEqual(ClipperFormat.compactDuration(3_600), "1h")
        XCTAssertEqual(ClipperFormat.compactDuration(4_800), "1h 20m")
    }

    func testCountdownRoundsUpSoItNeverShowsZeroEarly() {
        XCTAssertEqual(ClipperFormat.countdown(0.2), "00:01")
        XCTAssertEqual(ClipperFormat.countdown(59.5), "01:00")
    }
}

// MARK: - Live Activity content

final class ActivityContentTests: XCTestCase {

    func testContentStateRoundTripsThroughCoding() throws {
        let state = ClipperActivityAttributes.ContentState(phase: .speech,
                                                           speechSeconds: 120,
                                                           pendingJobs: 2,
                                                           isProcessing: true,
                                                           lowConfidence: true,
                                                           pausedAt: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder()
            .decode(ClipperActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    /// ActivityKit encodes this on every update, so it must stay small.
    func testContentStateStaysWellUnderAKilobyte() throws {
        let state = ClipperActivityAttributes.ContentState(phase: .listening,
                                                           speechSeconds: 9_999,
                                                           pendingJobs: 999,
                                                           isProcessing: true,
                                                           lowConfidence: true,
                                                           pausedAt: Date())
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 1_024)
    }

    func testProcessingLabelIsPluralisedAndAbsentWhenIdle() {
        func label(processing: Bool, jobs: Int) -> String? {
            ClipperActivityAttributes.ContentState(phase: .listening, pendingJobs: jobs,
                                                   isProcessing: processing).processingLabel
        }
        XCTAssertEqual(label(processing: true, jobs: 1), "1 clip processing")
        XCTAssertEqual(label(processing: true, jobs: 4), "4 clips processing")
        XCTAssertNil(label(processing: false, jobs: 4), "Not processing means no label")
        XCTAssertNil(label(processing: true, jobs: 0), "Nothing queued means no label")
    }

    func testAttributesCarryTheSessionIdentityForRecovery() {
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let attributes = ClipperActivityAttributes(sessionID: sessionID, startedAt: startedAt)

        XCTAssertEqual(attributes.sessionID, sessionID)
        XCTAssertEqual(attributes.startedAt, startedAt,
                       "The activity counts up from here without the app sending updates")
    }
}

// MARK: - Routing

final class AppRouterTests: XCTestCase {

    @MainActor
    func testEveryLinkSelectsTheRightTab() {
        let router = AppRouter.shared

        router.handle(.today)
        XCTAssertEqual(router.tab, .timeline)

        router.handle(.search("aurora"))
        XCTAssertEqual(router.tab, .search)
        XCTAssertEqual(router.searchText, "aurora")
        XCTAssertTrue(router.pendingSearchSubmit)

        let memoryID = UUID()
        router.handle(.memory(memoryID))
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.memoryRoute, .memory(memoryID))

        router.handle(.unresolved)
        XCTAssertEqual(router.memoryRoute, .unresolved,
                       "One route at a time: the previous destination is replaced, not stacked")

        router.handle(.listen)
        XCTAssertEqual(router.tab, .listen)
    }

    @MainActor
    func testAnUnparseableURLIsRejectedWithoutChangingTheTab() {
        let router = AppRouter.shared
        router.handle(.listen)
        let handled = router.handle(url: URL(string: "https://example.com")!)
        XCTAssertFalse(handled)
        XCTAssertEqual(router.tab, .listen)
    }

    @MainActor
    func testASearchWithNoQueryDoesNotAutoSubmit() {
        let router = AppRouter.shared
        router.searchText = ""
        router.pendingSearchSubmit = false
        router.handle(.search(nil))
        XCTAssertEqual(router.tab, .search)
        XCTAssertFalse(router.pendingSearchSubmit)
    }
}
