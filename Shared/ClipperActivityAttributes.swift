import ActivityKit
import Foundation

/// The Live Activity contract. Both processes compile this exact file, so the app and the
/// widget extension can never disagree about the layout.
///
/// `ContentState` is kept small and cheap to encode: ActivityKit serialises it on every
/// update, and Clipper updates on phase changes rather than on a timer, so the payload
/// should stay well under a kilobyte.
public struct ClipperActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var phase: ClipperPhase
        /// Speech seconds captured so far this session.
        public var speechSeconds: Double
        /// Utterances still queued for transcription/analysis.
        public var pendingJobs: Int
        public var isProcessing: Bool
        /// The room is noisy or music is bleeding in; results will be weaker.
        public var lowConfidence: Bool
        /// When the current pause started, so the Lock Screen can say how long.
        public var pausedAt: Date?

        public init(phase: ClipperPhase,
                    speechSeconds: Double = 0,
                    pendingJobs: Int = 0,
                    isProcessing: Bool = false,
                    lowConfidence: Bool = false,
                    pausedAt: Date? = nil) {
            self.phase = phase
            self.speechSeconds = speechSeconds
            self.pendingJobs = pendingJobs
            self.isProcessing = isProcessing
            self.lowConfidence = lowConfidence
            self.pausedAt = pausedAt
        }

        public var processingLabel: String? {
            guard isProcessing, pendingJobs > 0 else { return nil }
            return pendingJobs == 1 ? "1 clip processing" : "\(pendingJobs) clips processing"
        }
    }

    /// Fixed for the life of the activity.
    public var sessionID: UUID
    /// When capture started — the Live Activity counts up from here with a native timer,
    /// so the duration keeps ticking without the app sending updates.
    public var startedAt: Date

    public init(sessionID: UUID, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }
}
