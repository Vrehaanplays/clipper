import AVFoundation
import Foundation
import SwiftData
import XCTest

@testable import Clipper

// Shared fixtures. Two rules throughout the test suite:
//
// 1. **Nothing touches the real singletons.** Every store test builds its own in-memory
//    container, so tests cannot see each other's data and cannot corrupt the device's.
// 2. **Synthetic audio is deterministic.** The noise generator is a seeded LCG rather than
//    `Float.random`, so a VAD test that passes once passes every time.

enum TestAudio {
    static let sampleRate: Double = 16_000

    /// Near-silence. Not exact zero: a perfectly silent signal is not something a
    /// microphone ever produces, and the noise-floor tracker should see a real floor.
    static func silence(seconds: Double, amplitude: Float = 0.0005, sampleRate: Double = sampleRate) -> [Float] {
        noise(seconds: seconds, amplitude: amplitude, sampleRate: sampleRate, seed: 7)
    }

    /// Deterministic white noise via a linear congruential generator.
    static func noise(seconds: Double,
                      amplitude: Float,
                      sampleRate: Double = sampleRate,
                      seed: UInt64 = 42) -> [Float] {
        var state = seed
        let count = Int(seconds * sampleRate)
        var output = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 33) / Double(UInt32.max)) * 2 - 1
            output[i] = unit * amplitude
        }
        return output
    }

    /// A harmonic stack that behaves like voiced speech to the detector: strongly peaky
    /// spectrum, energy concentrated in the 300–3400 Hz band, and a 4 Hz syllable envelope.
    ///
    /// It is not speech and would not transcribe — it is a signal with the *shape* of
    /// speech, which is exactly what the VAD claims to key on.
    static func voiced(seconds: Double,
                       fundamental: Float = 120,
                       amplitude: Float = 0.25,
                       sampleRate: Double = sampleRate) -> [Float] {
        let count = Int(seconds * sampleRate)
        var output = [Float](repeating: 0, count: count)
        // Harmonics 2...25 of 120 Hz land at 240–3000 Hz, so most of the energy sits inside
        // the telephony band the detector measures.
        let harmonics = Array(2...25)
        var norm: Float = 0
        for h in harmonics { norm += 1 / Float(h) }

        for i in 0..<count {
            let t = Float(i) / Float(sampleRate)
            var sample: Float = 0
            for h in harmonics {
                sample += sin(2 * .pi * fundamental * Float(h) * t) / Float(h)
            }
            // Syllable-rate envelope, never fully closing.
            let envelope = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            output[i] = (sample / norm) * envelope * amplitude
        }
        return output
    }

    /// A tone far above the speech band — a chime or a UI sound.
    static func highTone(seconds: Double,
                         frequency: Float = 7_000,
                         amplitude: Float = 0.25,
                         sampleRate: Double = sampleRate) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            sin(2 * .pi * frequency * Float(i) / Float(sampleRate)) * amplitude
        }
    }

    /// Wrap mono samples in a buffer of the given format.
    static func buffer(_ samples: [Float], sampleRate: Double = sampleRate, channels: UInt32 = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels),
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            let destination = buffer.floatChannelData![channel]
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// Root-mean-square, in dB, of a signal.
    static func levelDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return SpectralAnalyzer.amplitudeToDB(sqrt(sum / Float(samples.count)))
    }

    /// Signal-to-noise ratio of `signal` against `reference`, treating the difference as
    /// noise. Used to check that the enhancer helps rather than hurts.
    static func snr(signal: [Float], reference: [Float]) -> Float {
        let count = min(signal.count, reference.count)
        guard count > 0 else { return 0 }
        var signalPower: Float = 0
        var errorPower: Float = 0
        for i in 0..<count {
            signalPower += reference[i] * reference[i]
            let error = signal[i] - reference[i]
            errorPower += error * error
        }
        guard errorPower > 0 else { return 100 }
        return 10 * log10(signalPower / errorPower)
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 1 else { return 0 }
        var meanA: Float = 0
        var meanB: Float = 0
        for i in 0..<count { meanA += a[i]; meanB += b[i] }
        meanA /= Float(count); meanB /= Float(count)

        var covariance: Float = 0
        var varianceA: Float = 0
        var varianceB: Float = 0
        for i in 0..<count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        return covariance / sqrt(varianceA * varianceB)
    }
}

// MARK: - Store fixtures

enum TestStore {
    /// A fresh in-memory store per call. Nothing is shared between tests.
    static func make() throws -> ClipperStore {
        let container = try ClipperDatabase.inMemory()
        return ClipperStore(modelContainer: container)
    }
}

/// A deterministic temporary directory, cleaned up by the test.
struct TempDirectory {
    let url: URL

    init(_ name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipperTests-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Messy synthetic corpus

/// One line of fake transcript, as the recogniser would hand it over: no punctuation in
/// places, repeated words, the odd mishearing.
struct CorpusLine {
    let speaker: String
    let text: String
    let offsetSeconds: Double
    let confidence: Double

    init(_ speaker: String, _ text: String, at offsetSeconds: Double, confidence: Double = 0.8) {
        self.speaker = speaker
        self.text = text
        self.offsetSeconds = offsetSeconds
        self.confidence = confidence
    }
}

/// The messy corpus the spec asks for: repeated statements, incomplete sentences,
/// background music, game sounds, multiple speakers, misheard words, unknown speakers,
/// contradictory claims, long silences, rapid topic changes and duplicate memories.
enum MessyCorpus {
    static let start = Date(timeIntervalSince1970: 1_780_000_000)

    static let lines: [CorpusLine] = [
        // Rapid topic change straight away, and an incomplete sentence.
        .init("Alex", "okay so about the aurora project we need to", at: 0),
        .init("Alex", "we decided we'll use Postgres for the aurora project", at: 6),
        // Repeated statement, slightly different words — must reinforce, not duplicate.
        .init("Sam", "so the plan is Postgres for aurora then", at: 14, confidence: 0.72),
        .init("Alex", "we decided we will use Postgres for aurora", at: 21),
        // A question.
        .init("Sam", "when is the aurora deadline again", at: 30),
        // An event with a date.
        .init("Alex", "the aurora deadline is on Friday", at: 36),
        // A mishearing: "Aurora" became "a roarer". Same topic, garbled.
        .init("Sam", "a roarer needs the migration script first", at: 44, confidence: 0.31),
        // Long silence, then a new subject entirely.
        .init("Alex", "different thing entirely I want to learn to sail this summer", at: 320),
        .init("Unknown voice", "mm hmm", at: 327, confidence: 0.2),
        // A preference, then a task.
        .init("Alex", "I prefer the morning sessions for that", at: 334),
        .init("Sam", "you need to book the boat before June", at: 341),
        // Much later: the decision changes. This must supersede, not sit alongside.
        .init("Alex", "we're moving aurora to SQLite instead of Postgres", at: 4_000),
        .init("Sam", "so we decided SQLite for the aurora project", at: 4_012),
        // A negated claim about the same thing — a contradiction of a different shape.
        .init("Alex", "we are not using Postgres for aurora", at: 4_030),
        // Noise that should never have been transcribed, kept to test ranking.
        .init("Unknown voice", "uh yeah okay yeah", at: 4_100, confidence: 0.18),
    ]

    /// Insert the corpus into a store, returning the ids it created.
    @discardableResult
    static func load(into store: ClipperStore) async -> (sessionID: UUID, lineIDs: [UUID]) {
        let sessionID = UUID()
        await store.startSession(id: sessionID,
                                 at: start,
                                 inputName: "iPhone Microphone",
                                 usedBuiltInMic: true,
                                 otherAudioPlaying: true)

        var speakerIDs: [String: UUID] = [:]
        let extractor = ContentExtractor()
        var lineIDs: [UUID] = []
        var previousKeywords: [String] = []

        for (index, line) in lines.enumerated() {
            // One stable cluster per name, with a hand-made feature vector so attribution is
            // deterministic rather than dependent on synthesised audio.
            let speakerID: UUID?
            if line.speaker == "Unknown voice" {
                speakerID = nil
            } else if let existing = speakerIDs[line.speaker] {
                speakerID = existing
            } else {
                let vector = signature(for: line.speaker)
                let match = await store.attributeSpeaker(embedding: vector, seconds: 6)
                speakerIDs[line.speaker] = match?.speakerID
                if let id = match?.speakerID {
                    await store.renameSpeaker(id: id, to: line.speaker)
                }
                speakerID = match?.speakerID
            }

            let startedAt = start.addingTimeInterval(line.offsetSeconds)
            let endedAt = startedAt.addingTimeInterval(5)
            let lineID = UUID()
            let lowConfidence = line.confidence < 0.45

            await store.insertTranscript(id: lineID,
                                         sessionID: sessionID,
                                         audioSegmentID: nil,
                                         speakerID: speakerID,
                                         speakerConfidence: speakerID == nil ? 0 : 0.7,
                                         startedAt: startedAt,
                                         endedAt: endedAt,
                                         index: index,
                                         text: line.text,
                                         confidence: line.confidence,
                                         audioQuality: lowConfidence ? 0.2 : 0.7,
                                         assertion: lowConfidence ? .uncertain : .stated,
                                         languageCode: "en-US",
                                         wordTimings: [],
                                         isLowConfidence: lowConfidence)
            lineIDs.append(lineID)

            let extraction = extractor.extract(from: line.text, occurredAt: startedAt)
            let shift = ContentExtractor.isTopicShift(from: previousKeywords, to: extraction.keywords)
            if !extraction.keywords.isEmpty { previousKeywords = extraction.keywords }

            let assignment = await store.assignConversation(segmentID: lineID,
                                                            sessionID: sessionID,
                                                            startedAt: startedAt,
                                                            endedAt: endedAt,
                                                            speakerID: speakerID,
                                                            confidence: line.confidence,
                                                            topicShift: shift)

            var nodeIDs: [UUID] = []
            for entity in extraction.entities {
                if let id = await store.upsertNode(kind: entity.kind,
                                                   name: entity.name,
                                                   mentionedAt: startedAt) {
                    nodeIDs.append(id)
                }
            }
            for keyword in extraction.keywords.prefix(3) {
                if let id = await store.upsertNode(kind: .topic, name: keyword, mentionedAt: startedAt) {
                    nodeIDs.append(id)
                }
            }
            if !nodeIDs.isEmpty {
                await store.attachNodes(conversationID: assignment.conversationID, nodeIDs: nodeIDs)
            }

            await store.insertExtractions(extraction.extractions,
                                          transcriptSegmentID: lineID,
                                          conversationID: assignment.conversationID,
                                          speakerID: speakerID,
                                          occurredAt: startedAt)

            await store.indexDocument(IndexCandidate(kind: .transcriptSegment,
                                                     refID: lineID,
                                                     conversationID: assignment.conversationID,
                                                     title: line.speaker,
                                                     text: line.text,
                                                     timestamp: startedAt,
                                                     speakerIDs: speakerID.map { [$0] } ?? [],
                                                     nodeIDs: nodeIDs,
                                                     importance: lowConfidence ? 0.1 : 0.3,
                                                     confidence: line.confidence,
                                                     assertion: lowConfidence ? .uncertain : .stated,
                                                     embedding: []))
            await store.setTranscriptState(id: lineID, state: .complete)
        }

        await store.endSession(id: sessionID, at: start.addingTimeInterval(4_200))
        return (sessionID, lineIDs)
    }

    /// A distinct, deterministic feature vector per name.
    static func signature(for name: String) -> [Float] {
        let seed = UInt64(abs(name.hashValue % 100_000) + 1)
        var state = seed
        var vector = [Float](repeating: 0, count: SpeakerFeatures.dimensions)
        for i in 0..<vector.count {
            state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
            vector[i] = Float(Double(state >> 40) / Double(UInt32.max >> 8)) - 0.5
        }
        return VectorMath.normalized(vector)
    }

    /// Close every conversation and build memories, the way the pipeline would.
    static func closeAndBuildMemories(in store: ClipperStore) async -> [MemoryDTO] {
        let closed = await store.closeInactiveConversations(asOf: start.addingTimeInterval(9_000),
                                                            inactiveFor: 60)
        let builder = MemoryBuilder()
        var built: [MemoryDTO] = []

        for conversationID in closed {
            guard let conversation = await store.conversation(id: conversationID) else { continue }
            let extractions = await store.extractions(conversationID: conversationID)
            let text = await store.transcriptLines(conversationID: conversationID)
                .map(\.text).joined(separator: " ")
            let keywords = ContentExtractor.keywords(in: text, limit: 8)

            let candidates = builder.build(extractions: extractions,
                                           conversation: conversation,
                                           keywords: keywords,
                                           nodeIDs: conversation.nodeIDs,
                                           summary: nil,
                                           summaryID: nil)
            for candidate in candidates {
                if let memory = await store.upsertMemory(candidate) {
                    built.append(memory)
                    await store.indexDocument(IndexCandidate(kind: .memory,
                                                             refID: memory.id,
                                                             conversationID: conversationID,
                                                             title: memory.title,
                                                             text: memory.detail.isEmpty ? memory.title : memory.detail,
                                                             timestamp: memory.lastSeenAt,
                                                             speakerIDs: [],
                                                             nodeIDs: memory.nodeIDs,
                                                             importance: memory.importance,
                                                             confidence: memory.confidence,
                                                             assertion: memory.assertion,
                                                             embedding: []))
                }
            }
        }
        return built
    }
}
