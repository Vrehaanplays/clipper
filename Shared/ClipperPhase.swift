import Foundation

/// The capture phase, in the vocabulary the user sees. Shared verbatim by the app, the
/// widget extension and the Live Activity, so all three can never disagree.
///
/// This is deliberately *narrower* than the app's internal `RecorderState`: it carries no
/// error strings and nothing device-specific, because it crosses a process boundary and is
/// persisted to disk. `RecorderState.phase` is the one place that maps between them.
public enum ClipperPhase: String, Codable, Hashable, CaseIterable, Sendable {
    /// Not capturing. No audio session held.
    case inactive
    /// Session activating, engine spinning up, no audio arrived yet.
    case starting
    /// Capturing, and the microphone is quiet — no speech right now.
    case listening
    /// Capturing, and voice activity is detected right now.
    case speech
    /// Paused by the user. Session still held so resuming is instant.
    case paused
    /// iOS took the microphone (call, Siri, another app). Recovery is armed.
    case interrupted
    /// Actively trying to get the engine back after an interruption or a route change.
    case recovering
    /// Microphone or speech permission is denied, so capture cannot start.
    case permissionDenied
    /// Capture stopped for a reason that was not a clean stop.
    case failed

    /// True when audio is genuinely reaching a file right now.
    public var isCapturingAudio: Bool {
        self == .listening || self == .speech
    }

    /// True while a session is meant to be running, including the transient states.
    public var isSessionActive: Bool {
        switch self {
        case .starting, .listening, .speech, .paused, .interrupted, .recovering:
            return true
        case .inactive, .permissionDenied, .failed:
            return false
        }
    }

    /// Short label. The same words everywhere: app, widget, Dynamic Island, Lock Screen.
    public var title: String {
        switch self {
        case .inactive: return "Not listening"
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .speech: return "Speech detected"
        case .paused: return "Paused"
        case .interrupted: return "Paused by iOS"
        case .recovering: return "Recovering"
        case .permissionDenied: return "Microphone off"
        case .failed: return "Stopped"
        }
    }

    /// Even shorter, for the Dynamic Island's compact presentation.
    public var compactTitle: String {
        switch self {
        case .inactive: return "Off"
        case .starting: return "Start"
        case .listening: return "Live"
        case .speech: return "Speech"
        case .paused: return "Paused"
        case .interrupted: return "Held"
        case .recovering: return "Retry"
        case .permissionDenied: return "No mic"
        case .failed: return "Stopped"
        }
    }

    public var symbolName: String {
        switch self {
        case .inactive: return "mic.slash"
        case .starting: return "mic.badge.plus"
        case .listening: return "waveform"
        case .speech: return "waveform.badge.mic"
        case .paused: return "pause.circle"
        case .interrupted: return "exclamationmark.triangle"
        case .recovering: return "arrow.clockwise"
        case .permissionDenied: return "mic.slash.circle"
        case .failed: return "xmark.circle"
        }
    }
}
