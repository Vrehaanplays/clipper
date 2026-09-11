import Foundation
import SwiftUI

/// Encoder presets tuned for speech, not music.
enum AudioQuality: Int, CaseIterable, Identifiable {
    case economy = 0
    case standard = 1
    case high = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .economy: return "Economy"
        case .standard: return "Standard"
        case .high: return "High"
        }
    }

    /// Per-channel target bit rate.
    private var bitRatePerChannel: Int {
        switch self {
        case .economy: return 24_000
        case .standard: return 32_000
        case .high: return 64_000
        }
    }

    func bitRate(forChannels channels: Int) -> Int {
        bitRatePerChannel * max(1, min(channels, 2))
    }

    var footprintLabel: String {
        let mbPerHour = Double(bitRatePerChannel) * 3600 / 8 / 1_000_000
        return String(format: "about %.0f MB per hour", mbPerHour)
    }
}

/// Immutable snapshot of the settings, safe to read from the audio and writer queues.
struct RecordingConfig {
    let clipDuration: TimeInterval
    let quality: AudioQuality
    let maxClipCount: Int
}

/// Deliberately tiny. The app is correct with every default untouched.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let clipMinuteChoices = [1, 2, 5, 10, 15]
    static let bufferMinuteChoices = [10, 15, 30, 60, 120]

    private enum Key {
        static let clipMinutes = "clipDurationMinutes"
        static let bufferMinutes = "bufferDurationMinutes"
        static let quality = "audioQuality"
    }

    private let defaults: UserDefaults

    @Published var clipMinutes: Int {
        didSet { defaults.set(clipMinutes, forKey: Key.clipMinutes) }
    }
    @Published var bufferMinutes: Int {
        didSet { defaults.set(bufferMinutes, forKey: Key.bufferMinutes) }
    }
    @Published var quality: AudioQuality {
        didSet { defaults.set(quality.rawValue, forKey: Key.quality) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clipMinutes: 5,      // product default
            Key.bufferMinutes: 30,   // product default: 6 x 5 min
            Key.quality: AudioQuality.standard.rawValue,
        ])
        self.clipMinutes = defaults.integer(forKey: Key.clipMinutes)
        self.bufferMinutes = defaults.integer(forKey: Key.bufferMinutes)
        self.quality = AudioQuality(rawValue: defaults.integer(forKey: Key.quality)) ?? .standard
    }

    /// Number of completed clips retained. A 30 min buffer of 5 min clips = 6.
    var maxClipCount: Int {
        Self.maxClipCount(clipMinutes: clipMinutes, bufferMinutes: bufferMinutes)
    }

    static func maxClipCount(clipMinutes: Int, bufferMinutes: Int) -> Int {
        guard clipMinutes > 0 else { return 1 }
        return max(1, bufferMinutes / clipMinutes)
    }

    /// Read straight from `UserDefaults` so background queues never touch `@Published`.
    var config: RecordingConfig {
        let clip = max(1, defaults.integer(forKey: Key.clipMinutes))
        let buffer = max(clip, defaults.integer(forKey: Key.bufferMinutes))
        return RecordingConfig(
            clipDuration: TimeInterval(clip) * 60,
            quality: AudioQuality(rawValue: defaults.integer(forKey: Key.quality)) ?? .standard,
            maxClipCount: Self.maxClipCount(clipMinutes: clip, bufferMinutes: buffer)
        )
    }
}
