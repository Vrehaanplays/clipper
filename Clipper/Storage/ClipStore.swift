import AVFoundation
import Combine
import Foundation

/// Owns the on-disk clip library: the directory, crash recovery, metadata and the
/// rolling-buffer deletion policy. Knows nothing about recording or the UI.
///
/// All `@Published` mutation happens on the main queue. Disk work is synchronous but
/// bounded (the directory holds a handful of files by construction).
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    /// Newest first.
    @Published private(set) var clips: [Clip] = []

    /// Set when a storage operation fails, so the UI can surface it honestly.
    @Published private(set) var storageError: String?

    let clipsDirectory: URL

    private let fileManager: FileManager
    private let settings: AppSettings

    /// `bootstrap()` is reachable from the main queue (app launch, foregrounding) and from
    /// the recorder's control queue (before capture starts), so the one-shot setup is
    /// guarded rather than assumed to be single-threaded.
    private let setupLock = NSLock()
    private var didBootstrap = false

    init(fileManager: FileManager = .default, settings: AppSettings = .shared) {
        self.fileManager = fileManager
        self.settings = settings

        // Application Support: persistent, private to the app sandbox, and backed up.
        // Never Caches or tmp — the system may evict those at will.
        let support = (try? fileManager.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.clipsDirectory = support.appendingPathComponent("Clips", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Create the directory, clean up crash debris, reload metadata and enforce the limit.
    /// Safe to call repeatedly; the expensive parts only run once per launch.
    func bootstrap() {
        setupLock.lock()
        ensureDirectoryExistsLocked()
        let isFirstRun = !didBootstrap
        didBootstrap = true
        if isFirstRun {
            purgePartialFiles()
        }
        setupLock.unlock()
        reload()
    }

    /// Call with `setupLock` held.
    private func ensureDirectoryExistsLocked() {
        guard !fileManager.fileExists(atPath: clipsDirectory.path) else { return }
        do {
            try fileManager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        } catch {
            setStorageError("Could not create the clips folder: \(error.localizedDescription)")
        }
    }

    /// A `.part` file means a recording was interrupted by a crash or a kill. It has no
    /// finalized MPEG-4 index and is not playable, so it is not a clip — discard it.
    /// Only `.part` files are ever removed here; completed clips are untouched.
    private func purgePartialFiles() {
        let names = (try? fileManager.contentsOfDirectory(atPath: clipsDirectory.path)) ?? []
        for name in names where (name as NSString).pathExtension == Clip.partialExtension {
            try? fileManager.removeItem(at: clipsDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Reading

    /// Rebuild the clip list from disk. This is the source of truth after a relaunch:
    /// the previous session is never assumed to have been correct.
    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: clipsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [Clip] = []
        var broken: [URL] = []

        for url in urls where url.pathExtension == Clip.finalExtension {
            if let clip = makeClip(at: url) {
                found.append(clip)
            } else {
                // Zero-length or undecodable: a genuinely dead file. Removing it can never
                // cost a valid recording, because validity is judged per file.
                broken.append(url)
            }
        }

        for url in broken { try? fileManager.removeItem(at: url) }

        found.sort { $0.startDate > $1.startDate }
        publish(found)
        enforceLimit()
    }

    /// Metadata comes from the filesystem and the audio file itself; the filename is only
    /// a fallback. That keeps chronological sorting correct even if a name is odd.
    private func makeClip(at url: URL) -> Clip? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { return nil }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        let duration = Double(file.length) / sampleRate

        let start = values?.creationDate
            ?? Clip.startDate(fromFilename: url.lastPathComponent)
            ?? values?.contentModificationDate?.addingTimeInterval(-duration)
            ?? Date(timeIntervalSince1970: 0)

        return Clip(url: url, startDate: start, duration: duration, byteSize: size)
    }

    // MARK: - Writing

    /// Called by the recorder once a segment has been finalized and moved into place.
    func adopt(_ clip: Clip) {
        onMain {
            var next = self.clips.filter { $0.url != clip.url }
            next.append(clip)
            next.sort { $0.startDate > $1.startDate }
            self.clips = next
            self.storageError = nil
            self.enforceLimitLocked()
        }
    }

    /// Trim to the newest `maxClipCount` clips, deleting the oldest first.
    func enforceLimit() {
        onMain { self.enforceLimitLocked() }
    }

    /// Main-queue only.
    private func enforceLimitLocked() {
        let limit = settings.maxClipCount
        guard clips.count > limit else { return }
        // `clips` is newest-first, so everything past the limit is the oldest material.
        let doomed = clips[limit...]
        for clip in doomed { try? fileManager.removeItem(at: clip.url) }
        clips = Array(clips.prefix(limit))
    }

    func delete(_ clip: Clip) {
        onMain {
            do {
                if self.fileManager.fileExists(atPath: clip.url.path) {
                    try self.fileManager.removeItem(at: clip.url)
                }
                self.clips.removeAll { $0.url == clip.url }
            } catch {
                self.setStorageError("Could not delete that clip: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Derived

    var bufferedDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.duration }
    }

    var totalBytes: Int64 {
        clips.reduce(0) { $0 + $1.byteSize }
    }

    var totalSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Free space on the volume holding the clips, in bytes.
    var availableCapacity: Int64? {
        guard let values = try? clipsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Plumbing

    func setStorageError(_ message: String?) {
        onMain { self.storageError = message }
    }

    private func publish(_ newClips: [Clip]) {
        onMain { self.clips = newClips }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
