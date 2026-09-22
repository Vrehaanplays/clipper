import Foundation
import XCTest

@testable import Clipper

/// Temporary: prints what the messy corpus actually produces, so the memory-layer
/// expectations can be checked against real extractor output instead of guesses.
final class CorpusDiagnosticsTests: XCTestCase {

    func testPrintWhatTheCorpusProduces() async throws {
        let store = try TestStore.make()
        _ = await MessyCorpus.load(into: store)

        let session = try await XCTUnwrap(await store.sessions().first)
        let lines = await store.transcriptLines(sessionID: session.id, limit: 100)
        print("[diag] lines=\(lines.count)")

        let conversations = await store.conversations(limit: 50)
        print("[diag] conversations=\(conversations.count)")

        let nodes = await store.nodes(limit: 100)
        print("[diag] nodes=\(nodes.count)")
        for node in nodes.prefix(25) {
            print("[diag] node kind=\(node.kind.rawValue) name=\(node.name) mentions=\(node.mentionCount)")
        }

        let builder = MemoryBuilder()
        for conversation in conversations {
            let extractions = await store.extractions(conversationID: conversation.id)
            let text = await store.transcriptLines(conversationID: conversation.id)
                .map(\.text).joined(separator: " ")
            let keywords = ContentExtractor.keywords(in: text, limit: 8)
            print("[diag] conversation \(conversation.id.uuidString.prefix(8)) extractions=\(extractions.count) keywords=\(keywords)")
            for extraction in extractions.prefix(30) {
                print("[diag]   extraction kind=\(extraction.kind.rawValue) subject=\(extraction.subject ?? "-") text=\(extraction.text)")
            }
            let candidates = builder.build(extractions: extractions,
                                           conversation: conversation,
                                           keywords: keywords,
                                           nodeIDs: conversation.nodeIDs,
                                           summary: nil,
                                           summaryID: nil)
            for candidate in candidates {
                print("[diag]   candidate kind=\(candidate.kind.rawValue) key=\(candidate.dedupeKey) title=\(candidate.title)")
            }
        }

        let built = await MessyCorpus.closeAndBuildMemories(in: store)
        print("[diag] built=\(built.count)")
        for memory in await store.memories(includeArchived: true, includeSuperseded: true, limit: 200) {
            print("[diag] memory kind=\(memory.kind.rawValue) occ=\(memory.occurrenceCount) rev=\(memory.revision) superseded=\(memory.supersededByID != nil) title=\(memory.title)")
        }
        print("[diag] contradictions=\(await store.contradictions(includeResolved: true, limit: 50).count)")
    }
}
