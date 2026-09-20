import Foundation
import SwiftData

/// Which audio lifecycle a stored segment belongs to. See `AudioLibrary` for the three
/// directories these map onto.
enum AudioSegmentKind: String, Codable, CaseIterable, Sendable {
    /// A 5-minute clip of everything heard. Temporary; the rolling buffer deletes it.
    case rolling
    /// One detected utterance, retained because a transcript cites it as evidence.
    case evidence
}

/// One capture session: from tapping Start to tapping Stop.
///
/// The raw layer records what the microphone did, separately from what was said. Session
/// rows are small and never deleted, so "when was Clipper actually listening?" stays
/// answerable years later even after the audio is long gone.
@Model
final class SessionRecord {
    #Index<SessionRecord>([\.startedAt])

    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?

    /// Seconds of *detected speech*, not seconds of wall clock.
    var speechSeconds: Double
    var utteranceCount: Int
    var interruptionCount: Int

    var inputName: String?
    var usedBuiltInMic: Bool
    /// Whether another app was playing audio when the session started — the Spotify case.
    var otherAudioPlaying: Bool

    init(id: UUID = UUID(),
         startedAt: Date = Date(),
         endedAt: Date? = nil,
         speechSeconds: Double = 0,
         utteranceCount: Int = 0,
         interruptionCount: Int = 0,
         inputName: String? = nil,
         usedBuiltInMic: Bool = true,
         otherAudioPlaying: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speechSeconds = speechSeconds
        self.utteranceCount = utteranceCount
        self.interruptionCount = interruptionCount
        self.inputName = inputName
        self.usedBuiltInMic = usedBuiltInMic
        self.otherAudioPlaying = otherAudioPlaying
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isOpen: Bool { endedAt == nil }
}

/// One audio file on disk, with the measurements that decide how much to trust anything
/// derived from it.
///
/// `audioAvailable` is what keeps the app honest after the retention policy runs: the row
/// survives, so the transcript can still say "the audio for this has expired" rather than
/// silently presenting a dead link.
@Model
final class AudioSegmentRecord {
    #Index<AudioSegmentRecord>([\.startedAt], [\.sessionID], [\.filename])

    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var kindRaw: String
    /// File name only. The directory comes from `AudioLibrary`, so moving the container
    /// (an OS upgrade, a restore) does not invalidate every row.
    var filename: String

    var startedAt: Date
    var endedAt: Date
    var sampleRate: Double
    var byteSize: Int64

    // Audio-quality metadata, stored because the spec requires it and because search
    // ranking uses it.
    var meanSNRDB: Double
    var peakLevelDB: Double
    var noiseFloorDB: Double
    /// Fraction of analysis windows that passed the VAD tests.
    var speechRatio: Double
    /// `SoundAnalysis` confidence that this is speech.
    var speechConfidence: Double
    /// `SoundAnalysis` confidence that this is music — the speaker-bleed indicator.
    var musicConfidence: Double
    var classifierLabel: String?

    var processingStateRaw: String
    /// False once the file has been removed by retention or by the user.
    var audioAvailable: Bool

    init(id: UUID = UUID(),
         sessionID: UUID,
         kind: AudioSegmentKind,
         filename: String,
         startedAt: Date,
         endedAt: Date,
         sampleRate: Double,
         byteSize: Int64 = 0,
         meanSNRDB: Double = 0,
         peakLevelDB: Double = -100,
         noiseFloorDB: Double = -55,
         speechRatio: Double = 0,
         speechConfidence: Double = 0,
         musicConfidence: Double = 0,
         classifierLabel: String? = nil,
         processingState: ProcessingState = .pending,
         audioAvailable: Bool = true) {
        self.id = id
        self.sessionID = sessionID
        self.kindRaw = kind.rawValue
        self.filename = filename
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sampleRate = sampleRate
        self.byteSize = byteSize
        self.meanSNRDB = meanSNRDB
        self.peakLevelDB = peakLevelDB
        self.noiseFloorDB = noiseFloorDB
        self.speechRatio = speechRatio
        self.speechConfidence = speechConfidence
        self.musicConfidence = musicConfidence
        self.classifierLabel = classifierLabel
        self.processingStateRaw = processingState.rawValue
        self.audioAvailable = audioAvailable
    }

    var kind: AudioSegmentKind {
        get { AudioSegmentKind(rawValue: kindRaw) ?? .rolling }
        set { kindRaw = newValue.rawValue }
    }

    var processingState: ProcessingState {
        get { ProcessingState(rawValue: processingStateRaw) ?? .pending }
        set { processingStateRaw = newValue.rawValue }
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// A single number for "how good is this audio", used to rank evidence and to decide
    /// whether to trust a transcript drawn from it.
    var qualityScore: Double {
        let snrScore = min(1, max(0, (meanSNRDB - 3) / 20))
        let speechScore = speechConfidence > 0 ? max(0, speechConfidence - 0.5 * musicConfidence) : speechRatio
        return 0.5 * snrScore + 0.5 * speechScore
    }
}
