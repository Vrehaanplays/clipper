import Foundation

/// The only channel between the app and the widget extension: one JSON file in the shared
/// container.
///
/// A *file* rather than `UserDefaults(suiteName:)` on purpose — `UserDefaults(suiteName:)`
/// hands back a usable-looking object even when the app group was never provisioned, and
/// the writes then silently go nowhere. `containerURL(forSecurityApplicationGroupIdentifier:)`
/// returns `nil` in that case, which is a truthful availability check we can surface in
/// Diagnostics instead of shipping a widget that mysteriously shows nothing.
public struct AppGroupStore {
    public static let groupIdentifier = "group.com.vrehaanplays.clipper"

    public static let shared = AppGroupStore()

    private let fileManager = FileManager.default
    private let snapshotName = "snapshot.json"

    public init() {}

    /// `nil` when the app group is not provisioned — which is the normal case for a build
    /// signed with a free Apple ID. See docs/WIDGETS.md.
    public var containerURL: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.groupIdentifier)
    }

    public var isAvailable: Bool { containerURL != nil }

    private var snapshotURL: URL? {
        containerURL?.appendingPathComponent(snapshotName, isDirectory: false)
    }

    // MARK: - Writing (app only)

    /// Atomic: encode, write to a sibling temp file, then replace. A widget reload that
    /// lands mid-write therefore reads the previous complete snapshot, never a torn one.
    @discardableResult
    public func write(_ snapshot: ClipperSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reading (widget and app)

    public func read() -> ClipperSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClipperSnapshot.self, from: data)
    }
}
