import Foundation
import Speech

struct TranscriptionOutput: Hashable, Sendable {
    var text: String
    /// 0...1. `confidenceReported` says whether this is the recogniser's own number or a
    /// stand-in, because on-device recognition sometimes reports zero for every segment
    /// and treating that as "no confidence" would mislabel good transcripts.
    var confidence: Double
    var confidenceReported: Bool
    var words: [WordTiming]
    var localeIdentifier: String
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case onDeviceUnavailable
    case emptyResult
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission is off. Turn it on in Settings › Privacy & Security › Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognition is not available for this language."
        case .onDeviceUnavailable:
            return "On-device speech recognition is not available yet. It downloads in the background the first time; Clipper will not send audio off the device."
        case .emptyResult:
            return "No speech was recognised in that audio."
        case .timedOut:
            return "Transcription took too long and was cancelled."
        case .failed(let message):
            return message
        }
    }
}

/// The transcription seam.
///
/// One conformance ships today (`OnDeviceSpeechTranscriber`). It exists as a protocol
/// because `SpeechAnalyzer`/`SpeechTranscriber` on iOS 26 is the obvious upgrade — better
/// quality and real word timings — and adding it should be a new conformance rather than
/// surgery on the pipeline. It is not adopted yet for the reasons in docs/LIMITATIONS.md.
protocol Transcribing: AnyObject {
    /// Recorded on the transcript so it is always clear which engine produced the text.
    var identifier: String { get }
    var isAvailable: Bool { get }
    var supportsOnDevice: Bool { get }
    func requestAuthorization() async -> Bool
    func transcribe(fileAt url: URL) async throws -> TranscriptionOutput
}

/// `SFSpeechRecognizer`, pinned to on-device recognition.
///
/// `requiresOnDeviceRecognition = true` is not a preference here, it is the product: with
/// it set, the framework will fail rather than fall back to Apple's servers, which is
/// exactly the guarantee this app makes. If the on-device model has not been downloaded
/// yet the error says so honestly instead of quietly using the network.
///
/// File-based rather than streaming, because the VAD has already decided what is worth
/// transcribing. That keeps the recogniser off the battery for the 95% of the day nobody is
/// talking, and sidesteps the duration limits a long-lived streaming task runs into.
final class OnDeviceSpeechTranscriber: Transcribing {
    let identifier = "SFSpeechRecognizer.onDevice"

    private let recognizer: SFSpeechRecognizer?
    private let localeIdentifier: String
    private let timeout: TimeInterval

    init(locale: Locale = Locale.current, timeout: TimeInterval = 90) {
        // Fall back to en-US if the device language has no recogniser, rather than
        // producing nothing at all.
        let candidate = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = candidate
        self.localeIdentifier = candidate?.locale.identifier ?? locale.identifier
        self.timeout = timeout
    }

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition == true
    }

    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    func transcribe(fileAt url: URL) async throws -> TranscriptionOutput {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.notAuthorized
        }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // Conversational speech, not a command or a search string.
        request.taskHint = .dictation

        let locale = localeIdentifier
        let deadline = timeout

        return try await withCheckedThrowingContinuation { continuation in
            // A recognition task can call back more than once, or never. The box makes
            // resuming exactly once a property of the code rather than a hope.
            let box = ContinuationBox(continuation)
            var task: SFSpeechRecognitionTask?

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.fail(TranscriptionError.failed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                box.succeed(Self.output(from: result.bestTranscription, locale: locale))
            }

            guard task != nil else {
                box.fail(TranscriptionError.recognizerUnavailable)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                guard box.isPending else { return }
                task?.cancel()
                box.fail(TranscriptionError.timedOut)
            }
        }
    }

    /// Map an `SFTranscription` onto our own output, including per-segment timings.
    ///
    /// `SFTranscriptionSegment` is word- or short-phrase-grained and carries `timestamp`,
    /// `duration` and `confidence`, which is where the transcript's word timings come from.
    static func output(from transcription: SFTranscription, locale: String) -> TranscriptionOutput {
        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)

        var words: [WordTiming] = []
        words.reserveCapacity(transcription.segments.count)
        var confidenceSum = 0.0
        var confidenceCount = 0

        for segment in transcription.segments {
            let confidence = Double(segment.confidence)
            if confidence > 0 {
                confidenceSum += confidence
                confidenceCount += 1
            }
            words.append(WordTiming(text: segment.substring,
                                    offset: segment.timestamp,
                                    duration: segment.duration,
                                    confidence: confidence))
        }

        let reported = confidenceCount > 0
        // 0.55 when nothing was reported: "we do not know", not "we are confident".
        let confidence = reported ? confidenceSum / Double(confidenceCount) : 0.55

        return TranscriptionOutput(text: text,
                                   confidence: confidence,
                                   confidenceReported: reported,
                                   words: words,
                                   localeIdentifier: locale)
    }
}

/// Resume-exactly-once wrapper for a callback API that may fire zero, one or many times.
private final class ContinuationBox {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TranscriptionOutput, Error>?

    init(_ continuation: CheckedContinuation<TranscriptionOutput, Error>) {
        self.continuation = continuation
    }

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    func succeed(_ output: TranscriptionOutput) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if output.text.isEmpty {
            pending.resume(throwing: TranscriptionError.emptyResult)
        } else {
            pending.resume(returning: output)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
