import Foundation

/// One completed, finalized recording on disk.
///
/// A `Clip` only ever describes a *finished* file. Files still being written live
/// under `Clip.partialExtension` and are never represented by this type.
struct Clip: Identifiable, Hashable {
    /// The file URL doubles as a stable identity — filenames are unique by timestamp.
    let url: URL
    /// Wall-clock time the first audio frame of this clip was captured.
    let startDate: Date
    /// Exact duration derived from frames written (or read back from the file).
    let duration: TimeInterval
    /// On-disk size in bytes.
    let byteSize: Int64

    var id: URL { url }

    // MARK: - Naming

    static let finalExtension = "m4a"
    static let partialExtension = "part"

    /// `2026-09-11_12-30-00`
    static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func filename(for date: Date) -> String {
        filenameFormatter.string(from: date)
    }

    /// Best-effort recovery of a start date from a filename. Used only as a fallback
    /// when filesystem metadata is unavailable.
    static func startDate(fromFilename name: String) -> Date? {
        let base = (name as NSString).deletingPathExtension
        return filenameFormatter.date(from: base)
    }

    // MARK: - Display

    var timeLabel: String {
        startDate.formatted(.dateTime.hour().minute())
    }

    var dayLabel: String {
        if Calendar.current.isDateInToday(startDate) { return "Today" }
        if Calendar.current.isDateInYesterday(startDate) { return "Yesterday" }
        return startDate.formatted(.dateTime.month(.abbreviated).day())
    }

    var durationLabel: String { Self.clockString(duration) }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// `m:ss` under an hour, `h:mm:ss` above.
    static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// `MM:SS`, used for the countdown readout.
    static func countdownString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    }
}
