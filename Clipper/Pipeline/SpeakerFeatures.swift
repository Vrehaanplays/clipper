import Accelerate
import Foundation

/// Voice feature vectors for speaker clustering.
///
/// ## What this is, and what it is not
/// iOS has **no public speaker-diarization or speaker-recognition API**. There is no
/// `SNSpeakerIdentityRequest`, and `Speech` does not expose who is talking. So this is a
/// hand-built approximation: mean and standard deviation of log-mel energies across the
/// voiced frames of an utterance, which captures the coarse timbre of a voice — vocal tract
/// length, brightness, roughness.
///
/// It reliably separates voices that are obviously different (an adult man and a child). It
/// does **not** reliably separate similar voices, and it drifts when the microphone distance
/// changes. Every attribution it produces therefore carries a confidence, is stored as a
/// cluster rather than a person, and is rendered as "Unknown voice" until the user names it.
/// `docs/LIMITATIONS.md` states this in the same terms.
///
/// The alternative — shipping a Core ML speaker-embedding model — was rejected: any model
/// good enough to be worth the download is either not redistributable or large enough to
/// dominate the app, and a wrong-but-confident speaker label is worse than an honest
/// unknown.
enum SpeakerFeatures {
    static let melBands = 26
    static let frameSize = 400      // 25 ms at 16 kHz
    static let hopSize = 160        // 10 ms at 16 kHz
    static let fftSize = 512
    static let lowFrequency: Float = 80
    static let highFrequency: Float = 7_600

    /// Feature vector length: mean and standard deviation per band.
    static var dimensions: Int { melBands * 2 }

    /// Returns an L2-normalised feature vector, or an empty array if the audio is too
    /// short or too quiet to describe a voice.
    static func embedding(from samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= frameSize * 8, sampleRate > 0 else { return [] }

        let filterbank = melFilterbank(sampleRate: sampleRate)
        guard !filterbank.isEmpty else { return [] }

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize)).rounded()),
                                               FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        let halfSize = fftSize / 2

        let window: [Float] = (0..<frameSize).map {
            0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(frameSize - 1))
        }

        var padded = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var power = [Float](repeating: 0, count: halfSize)

        var frames: [[Float]] = []
        var energies: [Float] = []
        let frameCount = (samples.count - frameSize) / hopSize + 1
        frames.reserveCapacity(frameCount)
        energies.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let offset = frame * hopSize
            for i in 0..<fftSize {
                padded[i] = i < frameSize ? samples[offset + i] * window[i] : 0
            }

            realp.withUnsafeMutableBufferPointer { realBuffer in
                imagp.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                imagp: imagBuffer.baseAddress!)
                    padded.withUnsafeMutableBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                             capacity: halfSize) { packed in
                            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfSize))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    power.withUnsafeMutableBufferPointer { output in
                        vDSP_zvmags(&split, 1, output.baseAddress!, 1, vDSP_Length(halfSize))
                    }
                }
            }

            var bands = [Float](repeating: 0, count: melBands)
            var total: Float = 0
            for band in 0..<melBands {
                var accumulated: Float = 0
                for (bin, gain) in filterbank[band] {
                    accumulated += power[bin] * gain
                }
                // Log energy, floored so silence does not produce -inf.
                bands[band] = log(max(accumulated, 1e-10))
                total += accumulated
            }
            frames.append(bands)
            energies.append(total)
        }

        guard !frames.isEmpty else { return [] }

        // Use only the louder half of the frames. Silence and breath between words carry
        // no speaker information and would pull every centroid toward each other.
        let sortedEnergies = energies.sorted()
        let threshold = sortedEnergies[sortedEnergies.count / 2]
        var selected = (0..<frames.count).filter { energies[$0] >= threshold }
        if selected.count < 4 { selected = Array(0..<frames.count) }

        var means = [Float](repeating: 0, count: melBands)
        for index in selected {
            for band in 0..<melBands { means[band] += frames[index][band] }
        }
        let count = Float(selected.count)
        for band in 0..<melBands { means[band] /= count }

        var deviations = [Float](repeating: 0, count: melBands)
        for index in selected {
            for band in 0..<melBands {
                let delta = frames[index][band] - means[band]
                deviations[band] += delta * delta
            }
        }
        for band in 0..<melBands { deviations[band] = sqrt(deviations[band] / count) }

        // Cepstral-mean-style centring: subtracting the overall level makes the vector
        // describe the *shape* of the voice rather than how loud it happened to be, which
        // is what lets one speaker match across a quiet and a loud utterance.
        let overallMean = means.reduce(0, +) / Float(melBands)
        let centred = means.map { $0 - overallMean }

        return VectorMath.normalized(centred + deviations)
    }

    /// Triangular mel filters as (bin, gain) pairs, built once per call.
    static func melFilterbank(sampleRate: Double) -> [[(Int, Float)]] {
        let halfSize = fftSize / 2
        let nyquist = Float(sampleRate / 2)
        let top = min(highFrequency, nyquist * 0.98)
        guard top > lowFrequency else { return [] }

        let lowMel = hertzToMel(lowFrequency)
        let highMel = hertzToMel(top)
        let points = (0...(melBands + 1)).map { index -> Float in
            melToHertz(lowMel + (highMel - lowMel) * Float(index) / Float(melBands + 1))
        }

        let binWidth = Float(sampleRate) / Float(fftSize)
        var filters: [[(Int, Float)]] = []
        filters.reserveCapacity(melBands)

        for band in 0..<melBands {
            let left = points[band]
            let centre = points[band + 1]
            let right = points[band + 2]
            var taps: [(Int, Float)] = []

            let firstBin = max(1, Int((left / binWidth).rounded(.down)))
            let lastBin = min(halfSize - 1, Int((right / binWidth).rounded(.up)))
            guard firstBin <= lastBin else {
                // Degenerate filter (very low sample rate); centre on one bin so the band
                // still contributes something rather than a constant.
                taps.append((min(halfSize - 1, max(1, Int(centre / binWidth))), 1))
                filters.append(taps)
                continue
            }

            for bin in firstBin...lastBin {
                let frequency = Float(bin) * binWidth
                var gain: Float = 0
                if frequency >= left && frequency <= centre, centre > left {
                    gain = (frequency - left) / (centre - left)
                } else if frequency > centre && frequency <= right, right > centre {
                    gain = (right - frequency) / (right - centre)
                }
                if gain > 0 { taps.append((bin, gain)) }
            }
            if taps.isEmpty {
                taps.append((min(halfSize - 1, max(1, Int(centre / binWidth))), 1))
            }
            filters.append(taps)
        }
        return filters
    }

    static func hertzToMel(_ hertz: Float) -> Float {
        2_595 * log10(1 + hertz / 700)
    }

    static func melToHertz(_ mel: Float) -> Float {
        700 * (pow(10, mel / 2_595) - 1)
    }
}
