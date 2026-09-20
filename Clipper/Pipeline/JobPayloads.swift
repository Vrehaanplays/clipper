import Foundation

// Job payloads are small JSON strings: ids, file names and the audio metrics that would
// otherwise have to be recomputed. Never audio, never transcript text — a job row must
// stay cheap to write and cheap to scan.

private let payloadEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private let payloadDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

protocol JobPayload: Codable {
    init?(json: String)
    var json: String { get }
}

extension JobPayload {
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? payloadDecoder.decode(Self.self, from: data) else { return nil }
        self = decoded
    }

    var json: String {
        guard let data = try? payloadEncoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// Everything needed to process one detected utterance, without touching the audio again
/// until the worker actually opens it.
struct UtterancePayload: JobPayload, Hashable {
    var utteranceID: UUID
    var sessionID: UUID
    var index: Int
    var startedAt: Date
    var endedAt: Date
    /// File name inside the utterances directory. The directory itself comes from
    /// `AudioLibrary`, so a container path change does not invalidate queued work.
    var filename: String
    var sampleRate: Double
    var frameCount: Int
    var meanSNRDB: Double
    var peakLevelDB: Double
    var noiseFloorDB: Double
    var speechRatio: Double
    var truncated: Bool
    var continuesPrevious: Bool

    init(utterance: PendingUtterance) {
        self.utteranceID = utterance.id
        self.sessionID = utterance.sessionID
        self.index = utterance.index
        self.startedAt = utterance.startedAt
        self.endedAt = utterance.endedAt
        self.filename = utterance.url.lastPathComponent
        self.sampleRate = utterance.sampleRate
        self.frameCount = utterance.frameCount
        self.meanSNRDB = utterance.meanSNRDB
        self.peakLevelDB = utterance.peakLevelDB
        self.noiseFloorDB = utterance.noiseFloorDB
        self.speechRatio = utterance.speechRatio
        self.truncated = utterance.truncated
        self.continuesPrevious = utterance.continuesPrevious
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// A conversation that has closed and is ready to be summarised.
struct ConversationPayload: JobPayload, Hashable {
    var conversationID: UUID
}

/// A day, week, topic or project rollup. `key` matches `SummaryRecord.key`.
struct RollupPayload: JobPayload, Hashable {
    var key: String
    var nodeID: UUID?

    init(key: String, nodeID: UUID? = nil) {
        self.key = key
        self.nodeID = nodeID
    }
}

/// Date keys for the summary hierarchy. Fixed POSIX formats so a key written last year
/// still parses under a different locale.
enum SummaryKey {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func week(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = components.yearForWeekOfYear ?? 1970
        let week = components.weekOfYear ?? 1
        return String(format: "%04d-W%02d", year, week)
    }

    static func dayBounds(_ date: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    static func weekBounds(_ date: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)
        let start = interval?.start ?? calendar.startOfDay(for: date)
        let end = interval?.end ?? start.addingTimeInterval(7 * 86_400)
        return (start, end)
    }

    /// Parse a day key back into its bounds, for regenerating an old rollup.
    static func bounds(forDayKey key: String) -> (start: Date, end: Date)? {
        guard let date = dayFormatter.date(from: key) else { return nil }
        return dayBounds(date)
    }

    static func bounds(forWeekKey key: String) -> (start: Date, end: Date)? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[1].hasPrefix("W"),
              let year = Int(parts[0]),
              let week = Int(parts[1].dropFirst()) else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = week
        components.weekday = calendar.firstWeekday
        guard let date = calendar.date(from: components) else { return nil }
        return weekBounds(date)
    }
}
