import Foundation

/// Everything the Home Screen widget is allowed to know, prepared by the app and written
/// to the shared container. The widget does no work of its own beyond rendering this —
/// no database, no audio, no model inference in the extension process.
public struct ClipperSnapshot: Codable, Hashable, Sendable {
    public var phase: ClipperPhase
    /// Start of the current capture session, for a live-counting duration.
    public var sessionStartedAt: Date?
    /// Seconds of *speech* captured in this session, not seconds of wall clock.
    public var speechSeconds: Double
    /// Utterances waiting on transcription or analysis.
    public var pendingJobs: Int
    /// True while the pipeline is working through that backlog.
    public var isProcessing: Bool
    /// True when the last few seconds of audio scored badly (loud room, music bleed).
    public var lowConfidence: Bool
    /// One-line headline of the most recent curated memory.
    public var recentMemory: String?
    /// One-line headline of the most recent conversation summary.
    public var recentSummary: String?
    /// Total memories held, so the widget can show something useful when idle.
    public var memoryCount: Int
    public var updatedAt: Date

    public init(phase: ClipperPhase = .inactive,
                sessionStartedAt: Date? = nil,
                speechSeconds: Double = 0,
                pendingJobs: Int = 0,
                isProcessing: Bool = false,
                lowConfidence: Bool = false,
                recentMemory: String? = nil,
                recentSummary: String? = nil,
                memoryCount: Int = 0,
                updatedAt: Date = Date()) {
        self.phase = phase
        self.sessionStartedAt = sessionStartedAt
        self.speechSeconds = speechSeconds
        self.pendingJobs = pendingJobs
        self.isProcessing = isProcessing
        self.lowConfidence = lowConfidence
        self.recentMemory = recentMemory
        self.recentSummary = recentSummary
        self.memoryCount = memoryCount
        self.updatedAt = updatedAt
    }

    public static let placeholder = ClipperSnapshot(
        phase: .inactive,
        recentMemory: "Open Clipper to start listening",
        memoryCount: 0
    )

    /// A snapshot older than this is stale: the app was killed mid-session and never got
    /// to write `inactive`. The widget shows the phase as unknown rather than lying.
    public static let staleAfter: TimeInterval = 15 * 60

    public var isStale: Bool {
        phase.isSessionActive && Date().timeIntervalSince(updatedAt) > Self.staleAfter
    }

    /// `12m 30s` of speech — the number the user actually cares about.
    public var speechLabel: String {
        ClipperFormat.compactDuration(speechSeconds)
    }
}

/// Duration formatting shared across the three targets so the widget, the Live Activity
/// and the app never render the same number differently.
public enum ClipperFormat {
    /// `m:ss` under an hour, `h:mm:ss` above.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// `MM:SS`, used for countdowns.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    }

    /// `45s`, `12m`, `1h 20m` — for labels where precision does not help.
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
