import Foundation
import OSLog

/// One place that owns logging and signposting.
///
/// Categories are chosen so that an Instruments trace can be filtered to a single stage of
/// the pipeline. The signpost intervals are the ones referenced in `docs/PERFORMANCE.md`:
/// open the "os_signpost" instrument, filter to the `Clipper` category, and every stage
/// below shows up as a named interval.
enum Log {
    static let subsystem = "com.vrehaanplays.clipper"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let vad = Logger(subsystem: subsystem, category: "vad")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let speakers = Logger(subsystem: subsystem, category: "speakers")
    static let model = Logger(subsystem: subsystem, category: "model")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let index = Logger(subsystem: subsystem, category: "index")
    static let graph = Logger(subsystem: subsystem, category: "graph")
    static let surfaces = Logger(subsystem: subsystem, category: "surfaces")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Signposts go to their own category so they do not drown the log stream.
    static let signposter = OSSignposter(subsystem: subsystem, category: "Clipper")

    // MARK: - Interval helpers

    /// Wrap a synchronous stage in a signpost interval.
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Wrap an asynchronous stage in a signpost interval.
    ///
    /// Named differently from the synchronous form on purpose: two overloads differing only
    /// in the closure's async-ness are a reliable source of confusing inference errors.
    @inline(__always)
    static func intervalAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Measure a stage and return the elapsed seconds alongside the result, for the
    /// numbers the Diagnostics screen shows. Uses the monotonic clock.
    @inline(__always)
    static func timed<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let state = signposter.beginInterval(name)
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        signposter.endInterval(name, state)
        return (value, elapsed)
    }

    @inline(__always)
    static func timedAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
        let state = signposter.beginInterval(name)
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        signposter.endInterval(name, state)
        return (value, elapsed)
    }
}
