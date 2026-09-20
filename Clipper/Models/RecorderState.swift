import SwiftUI

/// The *actual* state of the recording engine. The UI renders this and nothing else —
/// it never infers "Listening" from the fact that a button was tapped, and it never
/// reports capture while the engine is stopped.
///
/// `ClipperPhase` is the cross-process projection of this type (widget, Live Activity).
/// Anything that carries a device-specific reason string stays on this side of that line.
enum RecorderState: Equatable {
    /// Nothing running, no audio session held.
    case idle
    /// Session activating, engine spinning up, waiting for the first audio buffer.
    case starting
    /// Audio is genuinely flowing. `speech` is the live voice-activity decision.
    case listening(speech: Bool)
    /// Paused by the user. The session is still held so resuming is instant.
    case paused
    /// The system took the microphone away (call, Siri, another app, Control Center).
    case interrupted(reason: String?)
    /// Actively re-activating the session and restarting the engine.
    case recovering
    /// Tearing down, at the request of the user.
    case stopping
    /// Microphone or speech-recognition permission is off.
    case denied
    /// Not capturing, and it was not a clean stop. Carries a human-readable reason.
    case error(String)

    /// True while the engine is meant to be capturing, including transient states.
    var isActive: Bool { phase.isSessionActive }

    /// True only when audio is actually being captured to disk right now.
    var isCapturingAudio: Bool { phase.isCapturingAudio }

    /// True when the live voice-activity detector says someone is talking.
    var isSpeechDetected: Bool {
        if case .listening(let speech) = self { return speech }
        return false
    }

    var canPause: Bool {
        switch self {
        case .listening, .starting: return true
        default: return false
        }
    }

    var canResume: Bool { self == .paused }

    /// The projection shared with the widget and the Live Activity.
    var phase: ClipperPhase {
        switch self {
        case .idle: return .inactive
        case .starting: return .starting
        case .listening(let speech): return speech ? .speech : .listening
        case .paused: return .paused
        case .interrupted: return .interrupted
        case .recovering: return .recovering
        case .stopping: return .inactive
        case .denied: return .permissionDenied
        case .error: return .failed
        }
    }

    var title: String {
        switch self {
        case .stopping: return "Stopping"
        default: return phase.title
        }
    }

    var detail: String? {
        switch self {
        case .interrupted(let reason):
            return reason ?? "Waiting for the microphone to come back"
        case .recovering:
            return "Reconnecting to the microphone"
        case .denied:
            return "Turn the microphone on in Settings › Privacy & Security › Microphone"
        case .error(let message):
            return message
        case .paused:
            return "Nothing is being captured"
        default:
            return nil
        }
    }

    var tint: Color {
        switch self {
        case .listening(let speech): return speech ? .red : .pink
        case .starting, .stopping, .recovering: return .orange
        case .interrupted: return .yellow
        case .paused: return .secondary
        case .denied, .error: return .orange
        case .idle: return .secondary
        }
    }
}
