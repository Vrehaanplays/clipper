import AVFoundation
import XCTest

@testable import Clipper

/// Audio-session configuration, voice activity detection, enhancement and segment rotation.
///
/// None of these need a microphone: the session *plan* is pure policy, and everything else
/// runs on synthetic audio. That is deliberate — the parts of the audio stack that can be
/// tested without hardware are the parts most likely to be got wrong.
final class AudioSessionPlanTests: XCTestCase {

    /// The Spotify case, which is the product's headline requirement: another app's audio
    /// must be allowed to keep playing.
    func testDefaultPlanMixesWithOtherApps() {
        let config = AppSettings(defaults: Self.freshDefaults()).config
        let plan = AudioSessionPlan.capture(for: config)

        XCTAssertEqual(plan.category, .playAndRecord)
        XCTAssertEqual(plan.mode, .default)
        XCTAssertTrue(plan.options.contains(.mixWithOthers),
                      "Without .mixWithOthers, activating the session interrupts Spotify")
        XCTAssertTrue(plan.options.contains(.defaultToSpeaker),
                      ".playAndRecord routes to the earpiece otherwise, which breaks playback")
        XCTAssertTrue(plan.preferBuiltInMic)
        XCTAssertFalse(plan.voiceProcessing, "Voice processing ducks other apps; it must be opt-in")
    }

    /// The built-in microphone is a requirement, so no Bluetooth option may ever appear.
    func testPlanNeverAllowsBluetoothInput() {
        for letOthersPlay in [true, false] {
            for echo in [true, false] {
                var config = AppSettings(defaults: Self.freshDefaults()).config
                config.letOtherAppsPlay = letOthersPlay
                config.echoCancellation = echo
                let plan = AudioSessionPlan.capture(for: config)

                XCTAssertFalse(plan.options.contains(.allowBluetoothHFP))
                XCTAssertFalse(plan.options.contains(.allowBluetoothA2DP))
                XCTAssertTrue(plan.preferBuiltInMic)
            }
        }
    }

    func testEchoCancellationSwitchesToVoiceChatAndEnablesVoiceProcessing() {
        var config = AppSettings(defaults: Self.freshDefaults()).config
        config.echoCancellation = true
        let plan = AudioSessionPlan.capture(for: config)

        XCTAssertEqual(plan.mode, .voiceChat)
        XCTAssertTrue(plan.voiceProcessing)
    }

    func testExclusiveModeDropsMixing() {
        var config = AppSettings(defaults: Self.freshDefaults()).config
        config.letOtherAppsPlay = false
        let plan = AudioSessionPlan.capture(for: config)

        XCTAssertFalse(plan.options.contains(.mixWithOthers))
    }

    func testPlaybackPlanIsSeparate() {
        XCTAssertEqual(AudioSessionPlan.playback.category, .playback)
        XCTAssertFalse(AudioSessionPlan.playback.preferBuiltInMic)
    }

    static func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "clipper.tests.\(UUID().uuidString)")!
        return defaults
    }
}

// MARK: - Spectral analysis and VAD

final class VoiceActivityTests: XCTestCase {

    /// Voiced audio must be recognisably peaky, band-limited and bright-but-not-too-bright.
    func testVoicedAudioHasSpeechLikeSpectrum() {
        let analyzer = SpectralAnalyzer(sampleRate: TestAudio.sampleRate)
        var frames: [SpectralFrame] = []
        let samples = TestAudio.voiced(seconds: 1.0)
        samples.withUnsafeBufferPointer { pointer in
            analyzer.process(pointer.baseAddress!, count: samples.count) { frames.append($0) }
        }

        XCTAssertGreaterThan(frames.count, 40)
        let steady = frames.suffix(20)
        let meanFlatness = steady.map(\.flatness).reduce(0, +) / Float(steady.count)
        let meanVoiceBand = steady.map(\.voiceBandRatio).reduce(0, +) / Float(steady.count)
        let meanCentroid = steady.map(\.centroidHz).reduce(0, +) / Float(steady.count)

        XCTAssertLessThan(meanFlatness, 0.35, "A harmonic stack should be far from flat")
        XCTAssertGreaterThan(meanVoiceBand, 0.4, "Most energy should sit in 300–3400 Hz")
        XCTAssertTrue((80...4200).contains(meanCentroid), "Centroid was \(meanCentroid) Hz")
    }

    func testWhiteNoiseIsFlatAndRejected() {
        let analyzer = SpectralAnalyzer(sampleRate: TestAudio.sampleRate)
        let detector = VoiceActivityDetector(sensitivity: .balanced)
        var qualified = 0
        var total = 0

        let samples = TestAudio.noise(seconds: 2, amplitude: 0.08)
        samples.withUnsafeBufferPointer { pointer in
            analyzer.process(pointer.baseAddress!, count: samples.count) { frame in
                total += 1
                if detector.qualifiesAsSpeech(frame) { qualified += 1 }
            }
        }

        XCTAssertGreaterThan(total, 80)
        // A handful of frames may squeak through at onset before the floor adapts; the
        // point is that broadband noise is not treated as speech.
        XCTAssertLessThan(Double(qualified) / Double(total), 0.1,
                          "White noise should almost never qualify as speech")
    }

    func testHighFrequencyToneIsRejected() {
        let analyzer = SpectralAnalyzer(sampleRate: TestAudio.sampleRate)
        let detector = VoiceActivityDetector(sensitivity: .sensitive)
        var qualified = 0
        var total = 0

        let samples = TestAudio.silence(seconds: 0.6) + TestAudio.highTone(seconds: 1.0)
        samples.withUnsafeBufferPointer { pointer in
            analyzer.process(pointer.baseAddress!, count: samples.count) { frame in
                total += 1
                if detector.qualifiesAsSpeech(frame) { qualified += 1 }
            }
        }

        XCTAssertGreaterThan(total, 50)
        XCTAssertEqual(qualified, 0, "A 7 kHz chime is outside the speech band entirely")
    }

    /// Silence, then voice, then silence: the detector should open once and close once.
    func testOnsetAndOffsetFireExactlyOnce() {
        let analyzer = SpectralAnalyzer(sampleRate: TestAudio.sampleRate)
        let detector = VoiceActivityDetector(sensitivity: .balanced)

        var onsets = 0
        var offsets = 0
        let samples = TestAudio.silence(seconds: 1.0)
            + TestAudio.voiced(seconds: 1.5)
            + TestAudio.silence(seconds: 2.0)

        samples.withUnsafeBufferPointer { pointer in
            analyzer.process(pointer.baseAddress!, count: samples.count) { frame in
                switch detector.decide(frame) {
                case .onset: onsets += 1
                case .offset: offsets += 1
                default: break
                }
            }
        }

        XCTAssertEqual(onsets, 1, "The gate should open once for one utterance")
        XCTAssertEqual(offsets, 1, "And close once, after the hangover")
    }

    /// The hangover exists so a pause between words does not split one sentence in two.
    func testShortGapDoesNotSplitAnUtterance() {
        let analyzer = SpectralAnalyzer(sampleRate: TestAudio.sampleRate)
        let detector = VoiceActivityDetector(sensitivity: .balanced)

        var onsets = 0
        var offsets = 0
        let samples = TestAudio.silence(seconds: 1.0)
            + TestAudio.voiced(seconds: 0.8)
            + TestAudio.silence(seconds: 0.35)   // shorter than the 0.8 s hangover
            + TestAudio.voiced(seconds: 0.8)
            + TestAudio.silence(seconds: 2.0)

        samples.withUnsafeBufferPointer { pointer in
            analyzer.process(pointer.baseAddress!, count: samples.count) { frame in
                switch detector.decide(frame) {
                case .onset: onsets += 1
                case .offset: offsets += 1
                default: break
                }
            }
        }

        XCTAssertEqual(onsets, 1)
        XCTAssertEqual(offsets, 1)
    }

    func testSensitivityChangesTheThreshold() {
        XCTAssertGreaterThan(VADSensitivity.conservative.snrThresholdDB,
                             VADSensitivity.balanced.snrThresholdDB)
        XCTAssertGreaterThan(VADSensitivity.balanced.snrThresholdDB,
                             VADSensitivity.sensitive.snrThresholdDB)
        XCTAssertGreaterThan(VADSensitivity.conservative.minSpeechConfidence,
                             VADSensitivity.sensitive.minSpeechConfidence)
    }

    func testNoiseTrackerFollowsTheFloorDownFasterThanUp() {
        let tracker = NoiseTracker()
        for _ in 0..<200 { _ = tracker.update(levelDB: -30) }
        let settled = tracker.noiseFloorDB
        XCTAssertLessThan(abs(settled - -27), 6, "Floor should settle near the observed level")

        // A sudden quiet room: the floor should drop quickly.
        for _ in 0..<80 { _ = tracker.update(levelDB: -70) }
        XCTAssertLessThan(tracker.noiseFloorDB, settled - 10)
    }
}

// MARK: - Enhancement

final class SpeechEnhancerTests: XCTestCase {

    func testEnhancementImprovesSignalToNoise() {
        let enhancer = SpeechEnhancer()
        let clean = TestAudio.voiced(seconds: 1.5, amplitude: 0.25)
        let noise = TestAudio.noise(seconds: 1.5, amplitude: 0.06, seed: 99)
        let noisy = zip(clean, noise).map(+)

        let before = TestAudio.snr(signal: noisy, reference: clean)
        let after = TestAudio.snr(signal: enhancer.enhance(noisy), reference: clean)

        XCTAssertGreaterThan(after, before,
                             "Spectral subtraction should reduce the error against the clean signal")
    }

    /// The more important property: it must not wreck audio that was already fine.
    func testEnhancementPreservesCleanAudio() {
        let enhancer = SpeechEnhancer()
        let clean = TestAudio.voiced(seconds: 1.2, amplitude: 0.25)
        let processed = enhancer.enhance(clean)

        XCTAssertEqual(processed.count, clean.count)
        XCTAssertGreaterThan(TestAudio.correlation(processed, clean), 0.9,
                             "A clean signal should come back essentially unchanged")
    }

    func testCleanAudioSkipsEnhancementEntirely() {
        XCTAssertFalse(SpeechEnhancer.shouldEnhance(meanSNRDB: 30))
        XCTAssertTrue(SpeechEnhancer.shouldEnhance(meanSNRDB: 8))
    }

    func testShortInputIsReturnedUntouched() {
        let enhancer = SpeechEnhancer()
        let tiny = TestAudio.voiced(seconds: 0.02)
        XCTAssertEqual(enhancer.enhance(tiny), tiny)
    }

    func testWavRoundTrip() throws {
        let temp = TempDirectory("wav")
        defer { temp.remove() }

        let samples = TestAudio.voiced(seconds: 0.5, amplitude: 0.3)
        let url = temp.url.appendingPathComponent("a.wav")
        XCTAssertTrue(SpeechEnhancer.writeMono(samples, sampleRate: TestAudio.sampleRate, to: url))

        let read = try XCTUnwrap(SpeechEnhancer.readMono(url: url))
        XCTAssertEqual(read.sampleRate, TestAudio.sampleRate)
        // 16-bit quantisation on the way to disk, so compare shape rather than samples.
        XCTAssertEqual(read.samples.count, samples.count)
        XCTAssertGreaterThan(TestAudio.correlation(read.samples, samples), 0.99)
    }
}

// MARK: - Speaker features

final class SpeakerFeatureTests: XCTestCase {

    func testEmbeddingIsStableForTheSameVoice() {
        let a = SpeakerFeatures.embedding(from: TestAudio.voiced(seconds: 1.5, fundamental: 120),
                                          sampleRate: TestAudio.sampleRate)
        let b = SpeakerFeatures.embedding(from: TestAudio.voiced(seconds: 1.2, fundamental: 120,
                                                                 amplitude: 0.1),
                                          sampleRate: TestAudio.sampleRate)

        XCTAssertEqual(a.count, SpeakerFeatures.dimensions)
        XCTAssertFalse(b.isEmpty)
        // Cepstral-style centring is what makes this hold across a loud and a quiet take.
        XCTAssertGreaterThan(VectorMath.cosine(a, b), 0.9)
    }

    func testEmbeddingSeparatesObviouslyDifferentVoices() {
        let low = SpeakerFeatures.embedding(from: TestAudio.voiced(seconds: 1.5, fundamental: 95),
                                            sampleRate: TestAudio.sampleRate)
        let high = SpeakerFeatures.embedding(from: TestAudio.voiced(seconds: 1.5, fundamental: 240),
                                             sampleRate: TestAudio.sampleRate)

        XCTAssertLessThan(VectorMath.cosine(low, high), VectorMath.cosine(low, low) - 0.05,
                          "A 95 Hz and a 240 Hz voice should not look identical")
    }

    func testTooShortAudioProducesNoEmbedding() {
        XCTAssertTrue(SpeakerFeatures.embedding(from: TestAudio.voiced(seconds: 0.05),
                                                sampleRate: TestAudio.sampleRate).isEmpty)
    }

    func testMelFilterbankCoversTheSpeechBand() {
        let bank = SpeakerFeatures.melFilterbank(sampleRate: TestAudio.sampleRate)
        XCTAssertEqual(bank.count, SpeakerFeatures.melBands)
        for filter in bank {
            XCTAssertFalse(filter.isEmpty, "Every mel band must have at least one bin")
        }
    }
}

// MARK: - Rolling buffer

final class RollingBufferTests: XCTestCase {

    func testBufferSizeMath() {
        XCTAssertEqual(AppSettings.maxClipCount(clipMinutes: 5, bufferMinutes: 30), 6)
        XCTAssertEqual(AppSettings.maxClipCount(clipMinutes: 1, bufferMinutes: 30), 30)
        XCTAssertEqual(AppSettings.maxClipCount(clipMinutes: 15, bufferMinutes: 30), 2)
        // A buffer shorter than one clip still keeps one clip rather than none.
        XCTAssertEqual(AppSettings.maxClipCount(clipMinutes: 15, bufferMinutes: 10), 1)
        XCTAssertEqual(AppSettings.maxClipCount(clipMinutes: 0, bufferMinutes: 30), 1)
    }

    /// The core of the rotation mechanism: the buffer that crosses the boundary is split, so
    /// segments are exactly the requested length and no frame is dropped.
    func testSegmentWriterSplitsTheBoundaryBufferExactly() throws {
        let temp = TempDirectory("segment")
        defer { temp.remove() }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000,
                                   channels: 1,
                                   interleaved: false)!
        let writer = try SegmentWriter(directory: temp.url,
                                       startDate: Date(timeIntervalSince1970: 1_780_000_000),
                                       duration: 0.5,          // 24 000 frames
                                       quality: .standard,
                                       format: format)

        let chunk = TestAudio.voiced(seconds: 10_000.0 / 48_000.0, sampleRate: 48_000)
        let buffer = TestAudio.buffer(chunk, sampleRate: 48_000)
        XCTAssertEqual(buffer.frameLength, 10_000)

        if case .completed = try writer.write(buffer) { XCTFail("Too early") }
        if case .completed = try writer.write(buffer) { XCTFail("Still too early") }

        guard case .completed(let leftover) = try writer.write(buffer) else {
            return XCTFail("The third buffer must cross the 24 000-frame boundary")
        }
        let tail = try XCTUnwrap(leftover)
        XCTAssertEqual(tail.frameLength, 6_000, "20 000 + 4 000 written, 6 000 belongs to the next clip")
        XCTAssertEqual(writer.writtenDuration, 0.5, accuracy: 0.0001)

        let clip = try XCTUnwrap(writer.finish(), "Finalising should produce a playable clip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.url.path))
        XCTAssertEqual(clip.url.pathExtension, Clip.finalExtension)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partialURL.path),
                       "The .part file must be gone once it is finalised")
        XCTAssertGreaterThan(clip.byteSize, 0)
    }

    func testDiscardedSegmentLeavesNothingBehind() throws {
        let temp = TempDirectory("discard")
        defer { temp.remove() }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 1, interleaved: false)!
        let writer = try SegmentWriter(directory: temp.url,
                                       startDate: Date(),
                                       duration: 5,
                                       quality: .economy,
                                       format: format)
        _ = try writer.write(TestAudio.buffer(TestAudio.voiced(seconds: 0.2, sampleRate: 48_000),
                                              sampleRate: 48_000))
        writer.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.finalURL.path))
    }

    /// An exotic input format must become a reported error, never an uncatchable
    /// Objective-C exception from `AVAudioFile.write`.
    func testUnsupportedFormatThrowsRatherThanTrapping() {
        let temp = TempDirectory("format")
        defer { temp.remove() }

        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 48_000, channels: 2, interleaved: true)!
        XCTAssertThrowsError(try SegmentWriter(directory: temp.url,
                                               startDate: Date(),
                                               duration: 5,
                                               quality: .standard,
                                               format: interleaved))
    }

    func testBufferSliceCopiesFramesNotReferences() throws {
        let samples: [Float] = (0..<1_000).map { Float($0) / 1_000 }
        let buffer = TestAudio.buffer(samples, sampleRate: 48_000)

        let head = try XCTUnwrap(buffer.clipperSlice(from: 0, count: 400))
        let tail = try XCTUnwrap(buffer.clipperSlice(from: 400, count: 600))
        XCTAssertEqual(head.frameLength, 400)
        XCTAssertEqual(tail.frameLength, 600)
        XCTAssertEqual(head.floatChannelData![0][0], samples[0])
        XCTAssertEqual(tail.floatChannelData![0][0], samples[400])

        XCTAssertNil(buffer.clipperSlice(from: 900, count: 200), "Out-of-range slices must fail safely")
    }
}

// MARK: - Speech segmentation

final class SpeechSegmenterTests: XCTestCase {

    func testOneUtteranceIsEmittedWithPreRollAndCorrectTiming() throws {
        let temp = TempDirectory("segmenter")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url, sensitivity: .balanced)
        let audioStart = Date(timeIntervalSince1970: 1_780_000_000)
        var utterances: [PendingUtterance] = []
        segmenter.onUtterance = { utterances.append($0) }
        segmenter.begin(sessionID: UUID(), audioStart: audioStart)

        // ~100 ms chunks, the way the tap delivers them.
        let script = TestAudio.silence(seconds: 1.0)
            + TestAudio.voiced(seconds: 2.0)
            + TestAudio.silence(seconds: 2.0)
        feed(script, into: segmenter)

        XCTAssertEqual(utterances.count, 1, "One burst of speech is one utterance")
        let utterance = try XCTUnwrap(utterances.first)

        XCTAssertTrue(FileManager.default.fileExists(atPath: utterance.url.path))
        XCTAssertGreaterThan(utterance.duration, 2.0, "Pre-roll and hangover extend the clip")
        XCTAssertLessThan(utterance.duration, 4.2)
        // Timing is derived from counted samples, so the start must land near the 1 s mark
        // minus the 0.6 s pre-roll.
        let offset = utterance.startedAt.timeIntervalSince(audioStart)
        XCTAssertEqual(offset, 0.4, accuracy: 0.35, "Start was \(offset)s after the session's audio start")
        XCTAssertGreaterThan(utterance.speechRatio, 0.3)
        XCTAssertGreaterThan(utterance.meanSNRDB, 5)
        XCTAssertFalse(utterance.truncated)
    }

    func testSilenceProducesNothing() {
        let temp = TempDirectory("quiet")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url, sensitivity: .balanced)
        var utterances: [PendingUtterance] = []
        segmenter.onUtterance = { utterances.append($0) }
        segmenter.begin(sessionID: UUID(), audioStart: Date())

        feed(TestAudio.silence(seconds: 6), into: segmenter)
        segmenter.flush()

        XCTAssertTrue(utterances.isEmpty, "A quiet room must not create work")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: temp.url.path)) ?? []
        XCTAssertTrue(files.isEmpty, "And must not leave files behind")
    }

    func testTwoSeparatedBurstsBecomeTwoUtterances() throws {
        let temp = TempDirectory("two")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url, sensitivity: .balanced)
        var utterances: [PendingUtterance] = []
        segmenter.onUtterance = { utterances.append($0) }
        segmenter.begin(sessionID: UUID(), audioStart: Date())

        feed(TestAudio.silence(seconds: 1.0)
             + TestAudio.voiced(seconds: 1.2)
             + TestAudio.silence(seconds: 2.5)      // longer than the hangover
             + TestAudio.voiced(seconds: 1.2)
             + TestAudio.silence(seconds: 2.5),
             into: segmenter)

        XCTAssertEqual(utterances.count, 2)
        // Unwrapped, so a wrong count fails here instead of trapping.
        let first = try XCTUnwrap(utterances.first)
        let second = try XCTUnwrap(utterances.dropFirst().first)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(second.index, 2)
        XCTAssertLessThan(first.endedAt, second.startedAt)
    }

    /// Stopping mid-sentence must still keep what was captured.
    func testFlushClosesAnOpenUtterance() {
        let temp = TempDirectory("flush")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url, sensitivity: .balanced)
        var utterances: [PendingUtterance] = []
        segmenter.onUtterance = { utterances.append($0) }
        segmenter.begin(sessionID: UUID(), audioStart: Date())

        feed(TestAudio.silence(seconds: 0.8) + TestAudio.voiced(seconds: 1.5), into: segmenter)
        XCTAssertTrue(utterances.isEmpty, "Still mid-utterance")

        segmenter.flush()
        XCTAssertEqual(utterances.count, 1, "Audio captured before the stop must survive")
    }

    func testLongMonologueIsCappedAndContinues() {
        let temp = TempDirectory("cap")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url,
                                        sensitivity: .balanced,
                                        maxSeconds: 1.5)
        var utterances: [PendingUtterance] = []
        segmenter.onUtterance = { utterances.append($0) }
        segmenter.begin(sessionID: UUID(), audioStart: Date())

        feed(TestAudio.silence(seconds: 0.8) + TestAudio.voiced(seconds: 5.0), into: segmenter)
        segmenter.flush()

        XCTAssertGreaterThanOrEqual(utterances.count, 3, "A 5 s monologue at a 1.5 s cap splits")
        XCTAssertTrue(utterances.first?.truncated == true)
        XCTAssertTrue(utterances.dropFirst().allSatisfy(\.continuesPrevious),
                      "Continuations must be marked, so nothing looks like a separate thought")
        // Contiguous: each continuation starts where the last one ended.
        for pair in zip(utterances, utterances.dropFirst()) {
            XCTAssertEqual(pair.0.endedAt.timeIntervalSince1970,
                           pair.1.startedAt.timeIntervalSince1970,
                           accuracy: 0.01)
        }
    }

    func testMetricsReportSpeechAndQuiet() {
        let temp = TempDirectory("metrics")
        defer { temp.remove() }

        let segmenter = SpeechSegmenter(directory: temp.url, sensitivity: .balanced)
        var sawSpeech = false
        var sawQuiet = false
        segmenter.onMetrics = { metrics in
            if metrics.isSpeech { sawSpeech = true } else { sawQuiet = true }
        }
        segmenter.begin(sessionID: UUID(), audioStart: Date())

        feed(TestAudio.silence(seconds: 1.0) + TestAudio.voiced(seconds: 1.0)
             + TestAudio.silence(seconds: 2.0), into: segmenter)

        XCTAssertTrue(sawSpeech)
        XCTAssertTrue(sawQuiet)
    }

    /// Feed a signal in ~100 ms chunks, matching the real tap buffer size.
    private func feed(_ samples: [Float], into segmenter: SpeechSegmenter) {
        let chunk = Int(TestAudio.sampleRate / 10)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            segmenter.process(TestAudio.buffer(Array(samples[offset..<end])))
            offset = end
        }
    }
}

// MARK: - Downmixing

final class AudioDownmixerTests: XCTestCase {

    func testConvertsStereo48kToMono16k() throws {
        let downmixer = try XCTUnwrap(AudioDownmixer())
        let samples = TestAudio.voiced(seconds: 0.5, sampleRate: 48_000)
        let input = TestAudio.buffer(samples, sampleRate: 48_000, channels: 2)

        let output = try XCTUnwrap(downmixer.convert(input))
        XCTAssertEqual(output.format.sampleRate, AudioDownmixer.targetSampleRate)
        XCTAssertEqual(output.format.channelCount, 1)
        // Roughly a third of the input frames. The first buffer is short by the resampling
        // filter's own latency, which the converter pays back on the next buffer — that is
        // what `testAStreamOfBuffersKeepsAllOfItsAudio` pins.
        XCTAssertGreaterThan(Double(output.frameLength), Double(samples.count) / 3 * 0.8)
        XCTAssertLessThanOrEqual(Double(output.frameLength), Double(samples.count) / 3 + 64)
    }

    /// The property that actually matters: across a continuous stream, no audio is lost.
    /// The converter carries its filter state between calls, so the frames missing from
    /// the first buffer arrive with the ones after it.
    func testAStreamOfBuffersKeepsAllOfItsAudio() throws {
        let downmixer = try XCTUnwrap(AudioDownmixer())
        let perBuffer = TestAudio.voiced(seconds: 0.25, sampleRate: 48_000)

        var produced = 0
        for _ in 0..<8 {
            let input = TestAudio.buffer(perBuffer, sampleRate: 48_000, channels: 1)
            produced += Int(downmixer.convert(input)?.frameLength ?? 0)
        }

        let expected = Double(perBuffer.count * 8) / 3
        XCTAssertEqual(Double(produced), expected, accuracy: 256,
                       "A steady stream must come out at the full sample count")
    }

    func testEmptyBufferIsIgnored() throws {
        let downmixer = try XCTUnwrap(AudioDownmixer())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 1, interleaved: false)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        empty.frameLength = 0
        XCTAssertNil(downmixer.convert(empty))
    }
}
