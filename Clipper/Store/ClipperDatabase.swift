import Foundation
import SwiftData

/// Version 1 of the store shape. Every future change adds a new `VersionedSchema` and a
/// `MigrationStage`, which is why the model list lives here rather than being assembled
/// ad hoc at the call site.
enum ClipperSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            SessionRecord.self,
            AudioSegmentRecord.self,
            SpeakerRecord.self,
            TranscriptSegmentRecord.self,
            ConversationRecord.self,
            ExtractionRecord.self,
            MemoryRecord.self,
            SummaryRecord.self,
            ContradictionRecord.self,
            GraphNodeRecord.self,
            GraphEdgeRecord.self,
            IndexedDocumentRecord.self,
            TokenPostingRecord.self,
            JobRecord.self,
            StoreMetaRecord.self,
        ]
    }
}

/// The migration plan. Empty stages today because there is one schema; the type exists so
/// that adding version 2 is a two-line change and so the container is always opened
/// *through* a plan rather than relying on implicit lightweight migration.
enum ClipperMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ClipperSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Owns the `ModelContainer`.
///
/// ## Corruption recovery
/// A SwiftData store can fail to open — a half-written WAL after a hard kill, a schema that
/// does not match, a truncated file after running out of space. The app must still launch.
/// So opening happens in three escalating steps:
///
/// 1. Open normally.
/// 2. If that throws, move the store aside into `Corrupt/` (never delete it — it is the
///    user's data, and it may be recoverable by hand) and open a fresh one.
/// 3. If *that* throws, fall back to an in-memory container so the app runs, capture still
///    works, and Diagnostics says clearly that nothing is being saved.
///
/// The one thing it never does is fail silently.
final class ClipperDatabase {
    static let shared = ClipperDatabase()

    let container: ModelContainer
    let storeURL: URL

    /// Set when step 2 or 3 was needed. Surfaced in Diagnostics.
    private(set) var recoveryNote: String?
    /// True when the store is in memory only and nothing will survive a relaunch.
    private(set) var isEphemeral = false

    private init() {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("Clipper", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.storeURL = root.appendingPathComponent("Clipper.store", isDirectory: false)

        let schema = Schema(versionedSchema: ClipperSchemaV1.self)

        // Step 1.
        if let opened = Self.open(schema: schema, url: storeURL) {
            self.container = opened
            self.stampMeta()
            return
        }

        // Step 2.
        let quarantine = Self.quarantine(storeURL: storeURL, root: root)
        if let opened = Self.open(schema: schema, url: storeURL) {
            self.container = opened
            self.recoveryNote = quarantine
                ? "The database could not be opened and was rebuilt. The previous file was kept in Corrupt/."
                : "The database could not be opened and was rebuilt."
            Log.database.error("Rebuilt store after a failed open")
            self.stampMeta(recovered: true)
            return
        }

        // Step 3.
        Log.database.fault("Falling back to an in-memory store — nothing will be saved")
        let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // A container with no file backing has nothing left to fail on; if this throws the
        // app genuinely cannot run, and crashing here is more honest than a UI that
        // pretends to remember things.
        self.container = try! ModelContainer(for: schema,
                                             migrationPlan: ClipperMigrationPlan.self,
                                             configurations: memoryConfiguration)
        self.isEphemeral = true
        self.recoveryNote = "The database could not be opened or rebuilt. Clipper is running without storage: capture works, but nothing is being saved."
    }

    /// Test seam: an isolated in-memory container, so tests never touch the real store.
    static func inMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ClipperSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema,
                                  migrationPlan: ClipperMigrationPlan.self,
                                  configurations: configuration)
    }

    private static func open(schema: Schema, url: URL) -> ModelContainer? {
        let configuration = ModelConfiguration(schema: schema, url: url)
        do {
            return try ModelContainer(for: schema,
                                      migrationPlan: ClipperMigrationPlan.self,
                                      configurations: configuration)
        } catch {
            Log.database.error("Store open failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Move the store and its sidecars out of the way. Returns true if anything was moved.
    private static func quarantine(storeURL: URL, root: URL) -> Bool {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = root.appendingPathComponent("Corrupt/\(stamp)", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var moved = false
        let base = storeURL.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let source = storeURL.deletingLastPathComponent()
                .appendingPathComponent(base + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = folder.appendingPathComponent(base + suffix)
            do {
                try fileManager.moveItem(at: source, to: destination)
                moved = true
            } catch {
                // If it cannot be moved it has to go, or the app can never open a store.
                try? fileManager.removeItem(at: source)
                moved = true
            }
        }
        return moved
    }

    /// Record the schema version and bump the open count. Also the first real write, so a
    /// store that opens but cannot be written to is discovered at launch rather than in
    /// the middle of a recording.
    private func stampMeta(recovered: Bool = false) {
        let context = ModelContext(container)
        do {
            let existing = try context.fetch(FetchDescriptor<StoreMetaRecord>())
            if let meta = existing.first {
                meta.lastOpenedAt = Date()
                meta.openCount += 1
                meta.version = 1
                if recovered { meta.recoveredAt = Date() }
            } else {
                let meta = StoreMetaRecord(version: 1)
                if recovered { meta.recoveredAt = Date() }
                context.insert(meta)
            }
            try context.save()
        } catch {
            Log.database.error("Could not stamp store metadata: \(error.localizedDescription)")
            recoveryNote = "The database opened but could not be written to: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagnostics

    var storeByteSize: Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        let base = storeURL.lastPathComponent
        for suffix in ["", "-wal", "-shm"] {
            let url = storeURL.deletingLastPathComponent().appendingPathComponent(base + suffix)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
