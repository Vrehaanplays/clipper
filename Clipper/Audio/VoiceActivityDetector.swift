import Foundation

/// What the detector decided for one analysis window.
enum VADDecision: Equatable {
    /// Below the gate. Nothing is being collected.
    case silence
    /// Speech just started. The utterance assembler should open, including pre-roll.
    case onset
    /// Still inside speech.
    case speech
    /// Inside the hangover window: probably a pause between words, keep collecting.
    case hangover
    /// The hangover expired. Close the utterance.
    case offset
}

/// Energy-plus-shape voice activity detection with hysteresis.
///
/// iOS has no public VAD API, so this is hand-built. The design targets the actual problem
/// Clipper has: the phone's own speaker is playing Spotify or a game, so the microphone
/// physically hears it, and a pure energy gate would treat all of it as speech.
///
/// Three independent tests must agree before the gate opens:
///
/// 1. **SNR** above the running noise floor. Rejects steady room noise and fan hum, and
///    adapts when the user walks somewhere louder.
/// 2. **Spectral flatness** below a ceiling. Voiced speech is strongly harmonic, so it is
///    "peaky"; hiss, rain, crowd noise and most game ambience are flat.
/// 3. **Voice-band energy ratio** above a floor, with a centroid inside a plausible range.
///    Rejects clicks, cymbals, notification chimes and UI sounds, which sit far above the
///    3.4 kHz telephony band.
///
/// Music is the case this *cannot* fully solve — sung vocals are speech-shaped by
/// definition. That is what `SoundClassifier` is for, downstream: this gate decides what is
/// worth spending a classifier and a transcriber on, and the classifier decides what is
/// worth keeping. No claim is made that speaker bleed is perfectly separated.
final class VoiceActivityDetector {
    /// Consecutive qualifying windows required to open the gate. At a 16 ms hop this is
    /// ~48 ms, short enough not to clip a word onset (the pre-roll covers the rest).
    private let onsetFrames = 3
    /// How long to keep collecting after speech stops, so a pause between words does not
    /// split an utterance. ~0.8 s at a 16 ms hop.
    private let hangoverFrames = 50

    private let flatnessCeiling: Float = 0.42
    private let voiceBandFloor: Float = 0.30
    private let centroidRangeHz: ClosedRange<Float> = 80...4200

    private var sensitivity: VADSensitivity
    private var consecutiveSpeech = 0
    private var framesSinceSpeech = 0
    private var isOpen = false

    /// Rolling count of qualifying windows, used for the utterance's speech ratio.
    private(set) var speechFrames = 0
    private(set) var totalFrames = 0

    init(sensitivity: VADSensitivity = .balanced) {
        self.sensitivity = sensitivity
    }

    func update(sensitivity: VADSensitivity) {
        self.sensitivity = sensitivity
    }

    func reset() {
        consecutiveSpeech = 0
        framesSinceSpeech = 0
        isOpen = false
        speechFrames = 0
        totalFrames = 0
    }

    /// True while an utterance is being collected.
    var isCollecting: Bool { isOpen }

    /// Per-window decision. Pure function of the frame plus the detector's own history,
    /// which is what makes it testable against synthetic audio.
    func decide(_ frame: SpectralFrame) -> VADDecision {
        totalFrames += 1
        let qualifies = qualifiesAsSpeech(frame)
        if qualifies { speechFrames += 1 }

        if qualifies {
            consecutiveSpeech += 1
            framesSinceSpeech = 0
            if isOpen { return .speech }
            if consecutiveSpeech >= onsetFrames {
                isOpen = true
                return .onset
            }
            return .silence
        }

        consecutiveSpeech = 0
        guard isOpen else { return .silence }

        framesSinceSpeech += 1
        if framesSinceSpeech >= hangoverFrames {
            isOpen = false
            framesSinceSpeech = 0
            return .offset
        }
        return .hangover
    }

    /// Force the gate closed — used when capture stops or is interrupted mid-utterance.
    func forceClose() -> VADDecision {
        guard isOpen else { return .silence }
        isOpen = false
        consecutiveSpeech = 0
        framesSinceSpeech = 0
        return .offset
    }

    func qualifiesAsSpeech(_ frame: SpectralFrame) -> Bool {
        guard frame.snrDB >= sensitivity.snrThresholdDB else { return false }
        // An absolute floor as well as a relative one: in a near-anechoic room the noise
        // floor collapses and everything looks like a huge SNR.
        guard frame.levelDB > -62 else { return false }
        guard frame.flatness <= flatnessCeiling else { return false }
        guard frame.voiceBandRatio >= voiceBandFloor else { return false }
        guard centroidRangeHz.contains(frame.centroidHz) else { return false }
        return true
    }

    /// Fraction of windows in the current utterance that actually qualified. A low ratio
    /// means we collected mostly hangover — weak evidence, and it is recorded as such.
    var speechRatio: Double {
        totalFrames > 0 ? Double(speechFrames) / Double(totalFrames) : 0
    }
}
