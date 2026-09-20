import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// One thing to publish to system search.
struct SpotlightItem: Hashable, Sendable {
    var link: ClipperDeepLink
    var title: String
    var body: String
    var keywords: [String]
    var date: Date
    /// Shown as the item's type in Spotlight results.
    var kindLabel: String
}

/// Publishes conversations, summaries, memories, people and topics to Core Spotlight.
///
/// The `uniqueIdentifier` of every item **is** its `clipper://` deep link, so handling a
/// Spotlight tap is a URL parse rather than a lookup table that can drift out of sync with
/// the database. `ClipperDeepLink` is the single parser for both cases.
///
/// Only titles, summaries and keywords are published — never raw transcript text. Spotlight
/// content is readable by the system and surfaces on the Lock Screen, and full transcripts
/// of private conversations do not belong there. The in-app search index has everything;
/// this is a convenience surface.
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    static let domainIdentifier = "com.vrehaanplays.clipper.memory"

    private let index = CSSearchableIndex.default()

    private init() {}

    var isSupported: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    func publish(_ items: [SpotlightItem]) async {
        guard isSupported, !items.isEmpty else { return }

        let searchable = items.map { item -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
            attributes.title = item.title
            attributes.contentDescription = item.body
            attributes.keywords = item.keywords
            attributes.contentCreationDate = item.date
            attributes.contentModificationDate = item.date
            attributes.kind = item.kindLabel
            attributes.displayName = item.title

            let searchableItem = CSSearchableItem(
                uniqueIdentifier: item.link.url.absoluteString,
                domainIdentifier: Self.domainIdentifier,
                attributeSet: attributes
            )
            // Memories should stay findable; a year is long enough that the index does not
            // grow without bound if something is deleted outside the app.
            searchableItem.expirationDate = Date().addingTimeInterval(365 * 86_400)
            return searchableItem
        }

        await withCheckedContinuation { continuation in
            index.indexSearchableItems(searchable) { error in
                if let error {
                    Log.index.error("Spotlight indexing failed: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    func remove(links: [ClipperDeepLink]) async {
        guard isSupported, !links.isEmpty else { return }
        let identifiers = links.map { $0.url.absoluteString }
        await withCheckedContinuation { continuation in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error {
                    Log.index.error("Spotlight removal failed: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    /// Used when the user turns Spotlight indexing off, and when they erase everything.
    func removeAll() async {
        guard isSupported else { return }
        await withCheckedContinuation { continuation in
            index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
                if let error {
                    Log.index.error("Spotlight clear failed: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Builders

    static func item(for conversation: ConversationDTO, summary: SummaryDTO?) -> SpotlightItem {
        SpotlightItem(link: .conversation(conversation.id),
                      title: summary?.title ?? conversation.title,
                      body: summary?.text ?? "\(conversation.segmentCount) lines of conversation",
                      keywords: conversation.topicNames + conversation.speakerLabels,
                      date: conversation.startedAt,
                      kindLabel: "Clipper conversation")
    }

    static func item(for memory: MemoryDTO, topics: [String]) -> SpotlightItem {
        SpotlightItem(link: .memory(memory.id),
                      title: memory.title,
                      body: memory.detail.isEmpty ? memory.kind.title : memory.detail,
                      keywords: topics + [memory.kind.title],
                      date: memory.lastSeenAt,
                      kindLabel: "Clipper \(memory.kind.title.lowercased())")
    }

    static func item(for summary: SummaryDTO) -> SpotlightItem {
        SpotlightItem(link: .memory(summary.id),
                      title: summary.title,
                      body: summary.text,
                      keywords: summary.bullets.prefix(4).map { String($0.prefix(40)) },
                      date: summary.periodStart,
                      kindLabel: "Clipper \(summary.scope.title.lowercased()) summary")
    }

    static func item(for speaker: SpeakerDTO) -> SpotlightItem? {
        guard let name = speaker.displayName, !name.isEmpty else { return nil }
        return SpotlightItem(link: .speaker(speaker.id),
                             title: name,
                             body: "Heard for \(ClipperFormat.compactDuration(speaker.totalSpeechSeconds)) across \(speaker.sampleCount) clips",
                             keywords: [name, "person", "voice"],
                             date: speaker.createdAt,
                             kindLabel: "Clipper person")
    }

    static func item(for node: GraphNodeDTO) -> SpotlightItem {
        SpotlightItem(link: .node(node.id),
                      title: node.name,
                      body: "Mentioned \(node.mentionCount) time\(node.mentionCount == 1 ? "" : "s")",
                      keywords: [node.name, node.kind.title],
                      date: node.lastMentionedAt,
                      kindLabel: "Clipper \(node.kind.title.lowercased())")
    }
}
