import AVFoundation
import Foundation

/// One stretch of speech, written to disk and ready for the pipeline.
///
/// Audio timing comes from counted samples, not from wall clock: `startedAt` is the
/// session's audio start plus the sample offset. A late queue hop therefore cannot move a
/// timestamp, which matters because these timestamps are the evidence trail.
struct PendingUtterance: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    /// Position within the session, 1-based. Used for stable ordering when two utterances
    /// share a timestamp.
    let index: Int
    let startedAt: Date
    let endedAt: Date
    /// 16 kHz mono WAV in the utterances directory. Owned by the pipeline from here on.
    let url: URL
    let sampleRate: Double
    let frameCount: Int
    let meanSNRDB: Double
    let peakLevelDB: Double
    let noiseFloorDB: Double
    /// Fraction of analysis windows that actually passed the speech tests. Low values mean
    /// the utterance is mostly hangover or borderline audio.
    let speechRatio: Double
    /// True when this utterance is the continuation of one that hit the length cap.
    let continuesPrevious: Bool
    /// True when the length cap closed it rather than a real pause.
    let truncated: Bool

    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

/// Turns the continuous 16 kHz mono stream into discrete speech utterances.
///
/// Owns the FFT analysis, the VAD and a pre-roll ring buffer. Confined to the recorder's
/// analysis queue; nothing here touches the audio render thread or the main actor.
///
/// ### Why a pre-roll ring buffer
/// The gate needs a few windows of evidence before it opens, so by the time it does the
/// first syllable is already gone. The ring buffer holds the previous 0.6 s at all times,
/// and opening an utterance starts by draining it. The same idea at the other end is the
/// VAD's hangover, which keeps collecting through pauses between words.
///
/// ### Granularity
/// Decisions are applied at the granularity of one incoming buffer (~100 ms), not one
/// analysis window (16 ms). The pre-roll and the hangover are each many times larger than
/// that, so the imprecision is absorbed by design rather than papered over.
final class SpeechSegmenter {
    struct LiveMetrics: Equatable {
        var isSpeech: Bool
        var levelDB: Float
        var snrDB: Float
        var noiseFloorDB: Float
        /// Speech is being collected but the margin over the noise floor is thin — the
        /// user is told, because the transcript will be weaker.
        var lowConfidence: Bool
    }

    var onUtterance: ((PendingUtterance) -> Void)?
    var onMetrics: ((LiveMetrics) -> Void)?

    private let directory: URL
    private let sampleRate: Double
    private let analyzer: SpectralAnalyzer
    private let vad: VoiceActivityDetector
    private var sensitivity: VADSensitivity

    private let prerollSamples: Int
    private let minSamples: Int
    private let maxSamples: Int

    private var sessionID = UUID()
    private var audioStart = Date()
    private var totalSamples = 0
    private var utteranceIndex = 0

    // Pre-roll ring.
    private var ring: [Float]
    private var ringWrite = 0
    private var ringFilled = 0

    // Current utterance.
    private var collecting = false
    private var collected: [Float] = []
    private var collectStartSample = 0
    private var lastEndSample = 0
    private var continuesPrevious = false
    private var snrSum = 0.0
    private var snrCount = 0
    private var peakDB: Float = -100
    private var noiseDB: Float = -55
    private var qualifyingWindows = 0
    private var totalWindows = 0

    init(directory: URL,
         sampleRate: Double = AudioDownmixer.targetSampleRate,
         sensitivity: VADSensitivity = .balanced,
         prerollSeconds: TimeInterval = 0.6,
         minSeconds: TimeInterval = 0.5,
         maxSeconds: TimeInterval = 28) {
        self.directory = directory
        self.sampleRate = sampleRate
        self.sensitivity = sensitivity
        self.analyzer = SpectralAnalyzer(sampleRate: sampleRate)
        self.vad = VoiceActivityDetector(sensitivity: sensitivity)
        self.prerollSamples = Int(prerollSeconds * sampleRate)
        self.minSamples = Int(minSeconds * sampleRate)
        self.maxSamples = Int(maxSeconds * sampleRate)
        self.ring = Array(repeating: 0, count: max(1, prerollSamples))
        self.collected.reserveCapacity(maxSamples + Int(sampleRate))
    }

    // MARK: - Session lifecycle

    func begin(sessionID: UUID, audioStart: Date) {
        self.sessionID = sessionID
        self.audioStart = audioStart
        totalSamples = 0
        utteranceIndex = 0
        lastEndSample = 0
        ringWrite = 0
        ringFilled = 0
        collecting = false
        collected.removeAll(keepingCapacity: true)
        analyzer.reset()
        vad.reset()
    }

    /// The audio clock jumped — a route change or an interruption means the next samples
    /// are not contiguous with the last. Re-anchor rather than let timestamps drift.
    func reanchor(audioStart: Date) {
        flush()
        self.audioStart = audioStart
        totalSamples = 0
        lastEndSample = 0
        ringWrite = 0
        ringFilled = 0
        analyzer.reset()
        vad.reset()
    }

    func update(sensitivity: VADSensitivity) {
        guard sensitivity != self.sensitivity else { return }
        self.sensitivity = sensitivity
        vad.update(sensitivity: sensitivity)
    }

    /// Close any open utterance. Called on stop, pause and at the start of an interruption,
    /// so audio captured before the event still becomes evidence.
    func flush() {
        guard collecting else { return }
        _ = vad.forceClose()
        finalize(truncated: false)
    }

    // MARK: - Audio in

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)

        var sawOnset = false
        var sawOffset = false
        var liveSpeech = false
        var lastFrame = SpectralFrame.silent
        var thinMargin = false

        analyzer.process(channel, count: count) { frame in
            lastFrame = frame
            let decision = self.vad.decide(frame)

            switch decision {
            case .onset:
                sawOnset = true
                liveSpeech = true
            case .speech:
                liveSpeech = true
            case .hangover:
                liveSpeech = true
            case .offset:
                sawOffset = true
            case .silence:
                break
            }

            if self.collecting || sawOnset {
                self.totalWindows += 1
                self.snrSum += Double(frame.snrDB)
                self.snrCount += 1
                self.peakDB = max(self.peakDB, frame.levelDB)
                self.noiseDB = frame.noiseFloorDB
                if self.vad.qualifiesAsSpeech(frame) { self.qualifyingWindows += 1 }
                if frame.snrDB < self.sensitivity.snrThresholdDB + 3 { thinMargin = true }
            }
        }

        if sawOnset && !collecting {
            openCollection(continuing: false)
        }

        // The ring is always fed, so a second utterance starting soon after the last one
        // still gets its pre-roll.
        pushRing(channel, count: count)
        if collecting {
            collected.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }

        totalSamples += count

        if collecting && sawOffset {
            finalize(truncated: false)
        } else if collecting && collected.count >= maxSamples {
            // A long monologue: cut it at the cap and carry straight on, so nothing is
            // lost and no single job becomes unbounded.
            finalize(truncated: true)
            openCollection(continuing: true)
        }

        onMetrics?(LiveMetrics(isSpeech: liveSpeech,
                               levelDB: lastFrame.levelDB,
                               snrDB: lastFrame.snrDB,
                               noiseFloorDB: lastFrame.noiseFloorDB,
                               lowConfidence: liveSpeech && thinMargin))
    }

    // MARK: - Collection

    private func openCollection(continuing: Bool) {
        collecting = true
        continuesPrevious = continuing
        collected.removeAll(keepingCapacity: true)
        snrSum = 0
        snrCount = 0
        peakDB = -100
        qualifyingWindows = 0
        totalWindows = 0

        if continuing {
            collectStartSample = lastEndSample
        } else {
            let preroll = min(ringFilled, prerollSamples)
            collectStartSample = max(0, totalSamples - preroll)
            drainRing(into: &collected, count: preroll)
        }
    }

    private func finalize(truncated: Bool) {
        collecting = false
        defer { collected.removeAll(keepingCapacity: true) }

        let frames = collected.count
        lastEndSample = collectStartSample + frames

        // Too short to be speech worth transcribing. The audio is simply dropped; it was
        // never promoted out of the temporary buffer.
        guard frames >= minSamples else { return }

        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).wav", isDirectory: false)
        guard writeWAV(samples: collected, to: url) else {
            Log.audio.error("Could not write utterance audio")
            return
        }

        utteranceIndex += 1
        let start = audioStart.addingTimeInterval(Double(collectStartSample) / sampleRate)
        let end = audioStart.addingTimeInterval(Double(lastEndSample) / sampleRate)
        let meanSNR = snrCount > 0 ? snrSum / Double(snrCount) : 0
        let ratio = totalWindows > 0 ? Double(qualifyingWindows) / Double(totalWindows) : 0

        let utterance = PendingUtterance(
            id: id,
            sessionID: sessionID,
            index: utteranceIndex,
            startedAt: start,
            endedAt: end,
            url: url,
            sampleRate: sampleRate,
            frameCount: frames,
            meanSNRDB: meanSNR,
            peakLevelDB: Double(peakDB),
            noiseFloorDB: Double(noiseDB),
            speechRatio: ratio,
            continuesPrevious: continuesPrevious,
            truncated: truncated
        )

        Log.vad.debug("Utterance \(utterance.index) \(String(format: "%.1f", utterance.duration))s snr=\(String(format: "%.1f", meanSNR))dB ratio=\(String(format: "%.2f", ratio))")
        onUtterance?(utterance)
    }

    // MARK: - Ring buffer

    private func pushRing(_ samples: UnsafePointer<Float>, count: Int) {
        guard prerollSamples > 0 else { return }
        // Only the last `prerollSamples` can ever matter.
        let start = max(0, count - prerollSamples)
        for i in start..<count {
            ring[ringWrite] = samples[i]
            ringWrite = (ringWrite + 1) % prerollSamples
        }
        ringFilled = min(prerollSamples, ringFilled + (count - start))
    }

    /// Copy the newest `count` ring samples, oldest first.
    private func drainRing(into output: inout [Float], count: Int) {
        guard count > 0, prerollSamples > 0 else { return }
        let take = min(count, ringFilled)
        var index = (ringWrite - take + prerollSamples * 2) % prerollSamples
        for _ in 0..<take {
            output.append(ring[index])
            index = (index + 1) % prerollSamples
        }
    }

    // MARK: - WAV

    /// 16-bit linear PCM, 16 kHz mono — what `SFSpeechRecognizer` and `SNAudioFileAnalyzer`
    /// both want, and half the size of float32.
    private func writeWAV(samples: [Float], to url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            // Build the buffer from the file's own processing format. `AVAudioFile.write`
            // raises an uncatchable Objective-C exception on a format mismatch, so the
            // format is never assumed.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let destination = buffer.floatChannelData?[0] else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }
}
