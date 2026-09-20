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

/// How eager the voice-activity detector is. The trade-off is real and worth exposing:
/// a sensitive detector catches quiet speech across a room but also promotes TV, music
/// and game audio into the pipeline.
enum VADSensitivity: Int, CaseIterable, Identifiable {
    case conservative = 0
    case balanced = 1
    case sensitive = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .sensitive: return "Sensitive"
        }
    }

    var detail: String {
        switch self {
        case .conservative: return "Only clear, close speech. Fewest false positives."
        case .balanced: return "Recommended. Catches normal conversation in a room."
        case .sensitive: return "Quiet and distant speech too, but music and TV get through."
        }
    }

    /// Signal-to-noise ratio, in dB above the running noise floor, needed to open the gate.
    var snrThresholdDB: Float {
        switch self {
        case .conservative: return 11
        case .balanced: return 7
        case .sensitive: return 4.5
        }
    }

    /// Minimum classifier confidence for an utterance to be transcribed at all.
    var minSpeechConfidence: Double {
        switch self {
        case .conservative: return 0.45
        case .balanced: return 0.25
        case .sensitive: return 0.12
        }
    }
}

/// How long retained evidence audio is kept. Transcripts and memories are never deleted
/// by this policy — only the audio behind them.
enum EvidenceRetention: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case year = 365
    case forever = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "1 week"
        case .month: return "30 days"
        case .year: return "1 year"
        case .forever: return "Keep forever"
        }
    }

    var days: Int? { self == .forever ? nil : rawValue }
}

/// Immutable snapshot of every setting the audio and pipeline code needs, safe to read
/// from any queue. Nothing off the main actor ever touches `@Published`.
struct ClipperConfig: Equatable {
    var clipDuration: TimeInterval
    var quality: AudioQuality
    var maxClipCount: Int

    var letOtherAppsPlay: Bool
    var echoCancellation: Bool
    var sensitivity: VADSensitivity

    var transcriptionEnabled: Bool
    var speakerClusteringEnabled: Bool
    var summariesEnabled: Bool
    var preferOnDeviceModel: Bool

    var retention: EvidenceRetention
    var keepEvidenceAudio: Bool

    var liveActivityEnabled: Bool
    var widgetContentEnabled: Bool
    var spotlightEnabled: Bool
    var speakerNamingPrompts: Bool
}

/// User-facing settings. Small on the capture side, because the defaults are the product;
/// the extra switches all exist because they change a real trade-off the user can feel.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let clipMinuteChoices = [1, 2, 5, 10, 15]
    static let bufferMinuteChoices = [10, 15, 30, 60, 120]

    private enum Key {
        static let clipMinutes = "clipDurationMinutes"
        static let bufferMinutes = "bufferDurationMinutes"
        static let quality = "audioQuality"
        static let letOtherAppsPlay = "letOtherAppsPlay"
        static let echoCancellation = "echoCancellation"
        static let sensitivity = "vadSensitivity"
        static let transcription = "transcriptionEnabled"
        static let speakerClustering = "speakerClusteringEnabled"
        static let summaries = "summariesEnabled"
        static let onDeviceModel = "preferOnDeviceModel"
        static let retention = "evidenceRetentionDays"
        static let keepEvidence = "keepEvidenceAudio"
        static let liveActivity = "liveActivityEnabled"
        static let widgetContent = "widgetContentEnabled"
        static let spotlight = "spotlightEnabled"
        static let namingPrompts = "speakerNamingPrompts"
    }

    private let defaults: UserDefaults

    // MARK: - Rolling buffer

    @Published var clipMinutes: Int { didSet { defaults.set(clipMinutes, forKey: Key.clipMinutes) } }
    @Published var bufferMinutes: Int { didSet { defaults.set(bufferMinutes, forKey: Key.bufferMinutes) } }
    @Published var quality: AudioQuality { didSet { defaults.set(quality.rawValue, forKey: Key.quality) } }

    // MARK: - Capture

    @Published var letOtherAppsPlay: Bool { didSet { defaults.set(letOtherAppsPlay, forKey: Key.letOtherAppsPlay) } }
    @Published var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: Key.echoCancellation) } }
    @Published var sensitivity: VADSensitivity { didSet { defaults.set(sensitivity.rawValue, forKey: Key.sensitivity) } }

    // MARK: - Processing

    @Published var transcriptionEnabled: Bool { didSet { defaults.set(transcriptionEnabled, forKey: Key.transcription) } }
    @Published var speakerClusteringEnabled: Bool { didSet { defaults.set(speakerClusteringEnabled, forKey: Key.speakerClustering) } }
    @Published var summariesEnabled: Bool { didSet { defaults.set(summariesEnabled, forKey: Key.summaries) } }
    @Published var preferOnDeviceModel: Bool { didSet { defaults.set(preferOnDeviceModel, forKey: Key.onDeviceModel) } }
    @Published var speakerNamingPrompts: Bool { didSet { defaults.set(speakerNamingPrompts, forKey: Key.namingPrompts) } }

    // MARK: - Retention

    @Published var keepEvidenceAudio: Bool { didSet { defaults.set(keepEvidenceAudio, forKey: Key.keepEvidence) } }
    @Published var retention: EvidenceRetention { didSet { defaults.set(retention.rawValue, forKey: Key.retention) } }

    // MARK: - Surfaces (each independent, as required)

    @Published var liveActivityEnabled: Bool { didSet { defaults.set(liveActivityEnabled, forKey: Key.liveActivity) } }
    @Published var widgetContentEnabled: Bool { didSet { defaults.set(widgetContentEnabled, forKey: Key.widgetContent) } }
    @Published var spotlightEnabled: Bool { didSet { defaults.set(spotlightEnabled, forKey: Key.spotlight) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clipMinutes: 5,           // product default
            Key.bufferMinutes: 30,        // product default: 6 x 5 min
            Key.quality: AudioQuality.standard.rawValue,
            Key.letOtherAppsPlay: true,   // Spotify and games keep playing
            Key.echoCancellation: false,  // would duck other apps — opt in only
            Key.sensitivity: VADSensitivity.balanced.rawValue,
            Key.transcription: true,
            Key.speakerClustering: true,
            Key.summaries: true,
            Key.onDeviceModel: true,
            Key.retention: EvidenceRetention.year.rawValue,
            Key.keepEvidence: true,
            Key.liveActivity: true,
            Key.widgetContent: true,
            Key.spotlight: true,
            Key.namingPrompts: true,
        ])

        self.clipMinutes = defaults.integer(forKey: Key.clipMinutes)
        self.bufferMinutes = defaults.integer(forKey: Key.bufferMinutes)
        self.quality = AudioQuality(rawValue: defaults.integer(forKey: Key.quality)) ?? .standard
        self.letOtherAppsPlay = defaults.bool(forKey: Key.letOtherAppsPlay)
        self.echoCancellation = defaults.bool(forKey: Key.echoCancellation)
        self.sensitivity = VADSensitivity(rawValue: defaults.integer(forKey: Key.sensitivity)) ?? .balanced
        self.transcriptionEnabled = defaults.bool(forKey: Key.transcription)
        self.speakerClusteringEnabled = defaults.bool(forKey: Key.speakerClustering)
        self.summariesEnabled = defaults.bool(forKey: Key.summaries)
        self.preferOnDeviceModel = defaults.bool(forKey: Key.onDeviceModel)
        self.retention = EvidenceRetention(rawValue: defaults.integer(forKey: Key.retention)) ?? .year
        self.keepEvidenceAudio = defaults.bool(forKey: Key.keepEvidence)
        self.liveActivityEnabled = defaults.bool(forKey: Key.liveActivity)
        self.widgetContentEnabled = defaults.bool(forKey: Key.widgetContent)
        self.spotlightEnabled = defaults.bool(forKey: Key.spotlight)
        self.speakerNamingPrompts = defaults.bool(forKey: Key.namingPrompts)
    }

    /// Number of completed rolling clips retained. A 30 min buffer of 5 min clips = 6.
    var maxClipCount: Int {
        Self.maxClipCount(clipMinutes: clipMinutes, bufferMinutes: bufferMinutes)
    }

    static func maxClipCount(clipMinutes: Int, bufferMinutes: Int) -> Int {
        guard clipMinutes > 0 else { return 1 }
        return max(1, bufferMinutes / clipMinutes)
    }

    /// Read straight from `UserDefaults` so background queues never touch `@Published`.
    var config: ClipperConfig {
        let clip = max(1, defaults.integer(forKey: Key.clipMinutes))
        let buffer = max(clip, defaults.integer(forKey: Key.bufferMinutes))
        return ClipperConfig(
            clipDuration: TimeInterval(clip) * 60,
            quality: AudioQuality(rawValue: defaults.integer(forKey: Key.quality)) ?? .standard,
            maxClipCount: Self.maxClipCount(clipMinutes: clip, bufferMinutes: buffer),
            letOtherAppsPlay: defaults.bool(forKey: Key.letOtherAppsPlay),
            echoCancellation: defaults.bool(forKey: Key.echoCancellation),
            sensitivity: VADSensitivity(rawValue: defaults.integer(forKey: Key.sensitivity)) ?? .balanced,
            transcriptionEnabled: defaults.bool(forKey: Key.transcription),
            speakerClusteringEnabled: defaults.bool(forKey: Key.speakerClustering),
            summariesEnabled: defaults.bool(forKey: Key.summaries),
            preferOnDeviceModel: defaults.bool(forKey: Key.onDeviceModel),
            retention: EvidenceRetention(rawValue: defaults.integer(forKey: Key.retention)) ?? .year,
            keepEvidenceAudio: defaults.bool(forKey: Key.keepEvidence),
            liveActivityEnabled: defaults.bool(forKey: Key.liveActivity),
            widgetContentEnabled: defaults.bool(forKey: Key.widgetContent),
            spotlightEnabled: defaults.bool(forKey: Key.spotlight),
            speakerNamingPrompts: defaults.bool(forKey: Key.namingPrompts)
        )
    }
}
