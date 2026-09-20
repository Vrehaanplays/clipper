import AVFoundation
import Combine
import Foundation

/// Owns every audio file Clipper writes, and the three very different lifecycles they have.
///
/// | Directory | What it holds | Lifetime |
/// |---|---|---|
/// | `Rolling/` | the 5-minute clips of *everything* heard | newest N only (30 min by default), oldest deleted as each new one lands |
/// | `Utterances/` | 16 kHz mono WAV of one detected speech burst | deleted as soon as the pipeline is done with it |
/// | `Evidence/` | the same burst, AAC-encoded, kept because a transcript cites it | until the retention policy or the user removes it |
///
/// That separation is the point: the rolling buffer is *temporary audio* with no index and
/// no transcript, and `Evidence/` is *retained memory audio* that something in the database
/// points at. Nothing is ever promoted from rolling to evidence silently — only a detected
/// utterance becomes evidence.
///
/// Everything lives in Application Support: persistent, private to the sandbox, never
/// Caches or tmp, which the system may evict at will.
final class AudioLibrary: ObservableObject {
    static let shared = AudioLibrary()

    /// The rolling buffer, newest first.
    @Published private(set) var clips: [Clip] = []
    /// Set when a storage operation fails, so the UI can surface it honestly.
    @Published private(set) var storageError: String?

    let rootDirectory: URL
    let rollingDirectory: URL
    let utterancesDirectory: URL
    let evidenceDirectory: URL

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

        let support = (try? fileManager.url(for: .applicationSupportDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.rootDirectory = support.appendingPathComponent("Clipper", isDirectory: true)
        self.rollingDirectory = rootDirectory.appendingPathComponent("Rolling", isDirectory: true)
        self.utterancesDirectory = rootDirectory.appendingPathComponent("Utterances", isDirectory: true)
        self.evidenceDirectory = rootDirectory.appendingPathComponent("Evidence", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Create the directories, clean up crash debris, reload metadata and enforce the
    /// limit. Safe to call repeatedly; the expensive parts only run once per launch.
    func bootstrap() {
        setupLock.lock()
        for directory in [rootDirectory, rollingDirectory, utterancesDirectory, evidenceDirectory] {
            ensureDirectoryExistsLocked(directory)
        }
        let isFirstRun = !didBootstrap
        didBootstrap = true
        if isFirstRun {
            purgePartialFiles()
            excludeFromBackupIfNeeded()
        }
        setupLock.unlock()
        reload()
    }

    /// Call with `setupLock` held.
    private func ensureDirectoryExistsLocked(_ directory: URL) {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            setStorageError("Could not create Clipper's audio folder: \(error.localizedDescription)")
        }
    }

    /// The rolling buffer is transient by definition, and utterance WAVs are intermediates.
    /// Neither belongs in a device backup; evidence and the database do.
    private func excludeFromBackupIfNeeded() {
        for directory in [rollingDirectory, utterancesDirectory] {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// A `.part` file means a recording was interrupted by a crash or a kill. It has no
    /// finalized MPEG-4 index and is not playable, so it is not a clip — discard it.
    /// Only `.part` files are ever removed here; completed clips are untouched.
    private func purgePartialFiles() {
        let names = (try? fileManager.contentsOfDirectory(atPath: rollingDirectory.path)) ?? []
        for name in names where (name as NSString).pathExtension == Clip.partialExtension {
            try? fileManager.removeItem(at: rollingDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Rolling buffer

    /// Rebuild the clip list from disk. This is the source of truth after a relaunch:
    /// the previous session is never assumed to have been correct.
    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: rollingDirectory,
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
                // cost a valid recording, because validity is judged per file — a newer
                // clip is never deleted to clean up an older broken one.
                broken.append(url)
            }
        }

        for url in broken { try? fileManager.removeItem(at: url) }

        found.sort { $0.startDate > $1.startDate }
        onMain {
            self.clips = found
            self.enforceLimitLocked()
        }
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

    /// Called by the recorder once a rolling segment has been finalized and moved
    /// into place.
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
        for clip in clips[limit...] { try? fileManager.removeItem(at: clip.url) }
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

    /// File names currently in the rolling directory, read from disk rather than from the
    /// published `clips` array — callers off the main queue must never touch `@Published`.
    func rollingFilenames() -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: rollingDirectory.path)) ?? []
        return Set(names.filter { ($0 as NSString).pathExtension == Clip.finalExtension })
    }

    // MARK: - Utterances (intermediates)

    func utteranceURL(for id: UUID) -> URL {
        utterancesDirectory.appendingPathComponent("\(id.uuidString).wav", isDirectory: false)
    }

    func discardUtterance(at url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == utterancesDirectory.lastPathComponent
        else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Delete utterance WAVs that no job or transcript references any more — the debris a
    /// crash mid-pipeline leaves behind.
    func purgeOrphanUtterances(keeping live: Set<UUID>) {
        let urls = (try? fileManager.contentsOfDirectory(at: utterancesDirectory,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        var removed = 0
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else {
                try? fileManager.removeItem(at: url)
                removed += 1
                continue
            }
            if !live.contains(id) {
                try? fileManager.removeItem(at: url)
                removed += 1
            }
        }
        if removed > 0 { Log.database.notice("Purged \(removed) orphan utterance files") }
    }

    // MARK: - Evidence (retained memory audio)

    func evidenceURL(for id: UUID) -> URL {
        evidenceDirectory.appendingPathComponent("\(id.uuidString).m4a", isDirectory: false)
    }

    /// Re-encode a finished utterance WAV into `Evidence/` as AAC, roughly six times
    /// smaller, and return the new URL. The WAV is left alone — the caller decides when
    /// the intermediate goes.
    func retainEvidence(utteranceAt source: URL, id: UUID, quality: AudioQuality) -> URL? {
        let destination = evidenceURL(for: id)
        guard let (samples, sampleRate) = SpeechEnhancer.readMono(url: source),
              !samples.isEmpty else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: quality.bitRate(forChannels: 1),
        ]

        do {
            try? fileManager.removeItem(at: destination)
            let file = try AVAudioFile(forWriting: destination, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            return destination
        } catch {
            Log.database.error("Could not retain evidence audio: \(error.localizedDescription)")
            try? fileManager.removeItem(at: destination)
            return nil
        }
    }

    /// Apply the retention policy to evidence audio. Transcripts, memories and the graph are
    /// never touched by this — only the audio behind them, and the transcript keeps saying
    /// that its audio has expired rather than pretending it is still there.
    /// Returns the ids whose audio was removed.
    @discardableResult
    func sweepEvidence(retention: EvidenceRetention) -> [UUID] {
        guard let days = retention.days else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let urls = (try? fileManager.contentsOfDirectory(
            at: evidenceDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var expired: [UUID] = []
        for url in urls {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let created, created < cutoff else { continue }
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                expired.append(id)
            }
            try? fileManager.removeItem(at: url)
        }
        if !expired.isEmpty {
            Log.database.notice("Retention removed \(expired.count) evidence files")
        }
        return expired
    }

    func deleteEvidence(id: UUID) {
        try? fileManager.removeItem(at: evidenceURL(for: id))
    }

    /// Remove every retained clip. Only reachable from "Erase everything" in Settings.
    func deleteAllEvidence() {
        let urls = (try? fileManager.contentsOfDirectory(at: evidenceDirectory,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        for url in urls { try? fileManager.removeItem(at: url) }
        Log.database.notice("Deleted \(urls.count) evidence clips at the user's request")
    }

    // MARK: - Derived

    var bufferedDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.duration }
    }

    var totalRollingBytes: Int64 {
        clips.reduce(0) { $0 + $1.byteSize }
    }

    func byteSize(of directory: URL) -> Int64 {
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        return urls.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    var evidenceBytes: Int64 { byteSize(of: evidenceDirectory) }
    var utteranceBytes: Int64 { byteSize(of: utterancesDirectory) }

    var totalSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: totalRollingBytes, countStyle: .file)
    }

    /// Free space on the volume holding the recordings, in bytes.
    var availableCapacity: Int64? {
        guard let values = try? rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// True when the volume is too full to keep recording safely.
    var isStorageCritical: Bool {
        guard let available = availableCapacity else { return false }
        return available < 150 * 1_024 * 1_024
    }

    // MARK: - Plumbing

    func setStorageError(_ message: String?) {
        onMain { self.storageError = message }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
