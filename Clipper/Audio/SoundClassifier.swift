import Foundation
import SoundAnalysis

/// What Apple's built-in sound classifier thinks an utterance actually is.
struct SoundProfile: Equatable {
    /// Mean confidence for the `speech` class across the analysed windows.
    var speechConfidence: Double
    /// Mean confidence for music-like classes — the Spotify-through-the-speaker case.
    var musicConfidence: Double
    /// The single most confident label, for display and debugging.
    var topLabel: String?
    /// False when the classifier could not run at all (unsupported file, no model). The
    /// pipeline then relies on the VAD's own metrics and records lower confidence, rather
    /// than silently treating an unclassified utterance as clean speech.
    var available: Bool

    static let unavailable = SoundProfile(speechConfidence: 0, musicConfidence: 0,
                                          topLabel: nil, available: false)

    /// Combined judgement: strong speech and weak music. Used to decide whether an
    /// utterance is worth transcribing and how much to trust the result.
    var speechScore: Double {
        guard available else { return 0 }
        return max(0, speechConfidence - 0.5 * musicConfidence)
    }
}

/// Classifies a finished utterance with `SoundAnalysis`.
///
/// Runs on the finished file rather than on the live stream on purpose: the VAD has
/// already decided this audio is worth looking at, so the classifier runs at most once per
/// utterance instead of continuously, and it runs off the audio thread entirely. The cost
/// is a small latency, which does not matter for anything the user sees.
///
/// Its job is not to gate speech — that is the VAD's — but to *down-rank* audio that is
/// obviously not conversation. Sung vocals will always score as speech; no claim is made
/// otherwise.
final class SoundClassifier: Sendable {
    /// Labels in Apple's `version1` classifier that mean "this is not someone talking to
    /// me", checked as substrings because the taxonomy is large and versioned.
    private static let musicFragments = [
        "music", "singing", "guitar", "piano", "drum", "bass", "violin", "organ",
        "synthesizer", "choir", "orchestra", "harmonica", "accordion", "banjo", "cymbal",
    ]

    func classify(url: URL) async -> SoundProfile {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.classifySynchronously(url: url))
            }
        }
    }

    private func classifySynchronously(url: URL) -> SoundProfile {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url) else {
            return .unavailable
        }

        let collector = ClassificationCollector(musicFragments: Self.musicFragments)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: collector)
        } catch {
            Log.audio.error("Sound classifier unavailable: \(error.localizedDescription)")
            return .unavailable
        }

        // The synchronous form is correct here: we are already on a utility queue, and the
        // pipeline stage that called us is suspended awaiting the result.
        analyzer.analyze()
        return collector.profile()
    }
}

/// Accumulates windowed classification results. `SNResultsObserving` requires `NSObject`.
private final class ClassificationCollector: NSObject, SNResultsObserving {
    private let musicFragments: [String]
    private let lock = NSLock()

    private var speechTotal = 0.0
    private var musicTotal = 0.0
    private var windows = 0
    private var bestLabel: String?
    private var bestConfidence = 0.0
    private var failed = false

    init(musicFragments: [String]) {
        self.musicFragments = musicFragments
        super.init()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        var speech = 0.0
        var music = 0.0
        for item in classification.classifications {
            let identifier = item.identifier.lowercased()
            let confidence = item.confidence

            if identifier == "speech" {
                speech = max(speech, confidence)
            }
            if musicFragments.contains(where: { identifier.contains($0) }) {
                music = max(music, confidence)
            }
        }

        // The framework returns classifications sorted by confidence.
        let top = classification.classifications.first

        lock.lock()
        speechTotal += speech
        musicTotal += music
        windows += 1
        if let top, top.confidence > bestConfidence {
            bestConfidence = top.confidence
            bestLabel = top.identifier
        }
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.audio.error("Sound classification failed: \(error.localizedDescription)")
        lock.lock()
        failed = true
        lock.unlock()
    }

    func requestDidComplete(_ request: SNRequest) {}

    func profile() -> SoundProfile {
        lock.lock()
        defer { lock.unlock() }
        guard windows > 0, !failed else { return .unavailable }
        return SoundProfile(
            speechConfidence: speechTotal / Double(windows),
            musicConfidence: musicTotal / Double(windows),
            topLabel: bestLabel,
            available: true
        )
    }
}
