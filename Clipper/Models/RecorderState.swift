import SwiftUI

/// The *actual* state of the recording engine. The UI renders this and nothing else —
/// it never infers "Recording" from the fact that a button was tapped.
enum RecorderState: Equatable {
    /// Nothing running, no audio session held.
    case idle
    /// Session activating, engine spinning up, waiting for the first audio buffer.
    case starting
    /// Audio is genuinely flowing into a segment file.
    case recording
    /// A segment boundary was hit; the file is being closed and moved into place.
    case finalizing
    /// The system took the microphone away (call, Siri, another app). Recovery is armed.
    case interrupted
    /// Tearing down, at the request of the user.
    case stopping
    /// Not recording, and it was not a clean stop. Carries a human-readable reason.
    case error(String)

    /// True while the engine is meant to be capturing, including transient states.
    var isActive: Bool {
        switch self {
        case .starting, .recording, .finalizing, .interrupted: return true
        case .idle, .stopping, .error: return false
        }
    }

    /// True only when audio is actually being captured to disk right now.
    var isCapturingAudio: Bool {
        self == .recording || self == .finalizing
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .finalizing: return "Saving clip"
        case .interrupted: return "Interrupted"
        case .stopping: return "Stopping"
        case .error: return "Stopped"
        }
    }

    var detail: String? {
        switch self {
        case .interrupted: return "Waiting for the mic to come back"
        case .error(let message): return message
        default: return nil
        }
    }

    var tint: Color {
        switch self {
        case .recording, .finalizing: return .red
        case .starting, .stopping: return .orange
        case .interrupted: return .yellow
        case .error: return .orange
        case .idle: return .secondary
        }
    }
}
