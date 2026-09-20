import Accelerate
import AVFoundation
import Foundation

/// Single-channel noise suppression, applied to an utterance before transcription.
///
/// Classic spectral subtraction with a per-bin noise estimate taken from the quietest
/// frames of the utterance itself, deliberately tuned **conservative**: the floor keeps
/// 15% of every bin so nothing is ever gated to silence, and the over-subtraction factor
/// is 1.2 rather than the 2–3 typical of aggressive denoisers. Over-suppression removes
/// consonants, and a transcriber misses more words from a gated signal than from a noisy
/// one.
///
/// It is also skipped entirely when the utterance is already clean (see
/// `shouldEnhance(meanSNRDB:)`), so the common case pays nothing.
///
/// This is not `AVAudioUnitEQ` or hardware voice processing: those operate on the live
/// stream. Running the reduction offline, on a bounded 28-second buffer, keeps it off the
/// audio thread entirely.
final class SpeechEnhancer {
    private let fftSize: Int
    private let hop: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private var window: [Float]

    /// Below this SNR the utterance is worth cleaning up; above it, enhancement can only
    /// do harm.
    static let enhancementSNRCeiling = 18.0

    init(fftSize: Int = 512) {
        let size = max(64, 1 << Int(log2(Double(fftSize)).rounded()))
        self.fftSize = size
        self.hop = size / 2
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        // Periodic Hann. At 50% overlap it sums to exactly 1.0, so overlap-add needs no
        // synthesis window and no normalisation pass.
        self.window = (0..<size).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(size))) }
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    static func shouldEnhance(meanSNRDB: Double) -> Bool {
        meanSNRDB < enhancementSNRCeiling
    }

    /// Returns the cleaned signal, or the input unchanged if the FFT is unavailable or the
    /// signal is too short to analyse.
    func enhance(_ samples: [Float]) -> [Float] {
        guard let setup, samples.count >= fftSize * 3 else { return samples }

        let frameCount = (samples.count - fftSize) / hop + 1
        guard frameCount >= 3 else { return samples }

        var realParts = [[Float]]()
        var imagParts = [[Float]]()
        var magnitudes = [[Float]]()
        realParts.reserveCapacity(frameCount)
        imagParts.reserveCapacity(frameCount)
        magnitudes.reserveCapacity(frameCount)

        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var windowed = [Float](repeating: 0, count: fftSize)

        // ---- Analysis
        for frame in 0..<frameCount {
            let offset = frame * hop
            samples.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            forward(setup: setup, input: &windowed, realp: &realp, imagp: &imagp)

            var magnitude = [Float](repeating: 0, count: halfSize)
            for bin in 0..<halfSize {
                magnitude[bin] = sqrt(realp[bin] * realp[bin] + imagp[bin] * imagp[bin])
            }
            realParts.append(realp)
            imagParts.append(imagp)
            magnitudes.append(magnitude)
        }

        // ---- Per-bin noise estimate: the 20th percentile across time.
        // A percentile rather than the minimum, because a single quiet frame in a bin is
        // often just a phase cancellation rather than the true noise level there.
        let percentileIndex = max(0, Int(Double(frameCount) * 0.2) - 1)
        var noise = [Float](repeating: 0, count: halfSize)
        var column = [Float](repeating: 0, count: frameCount)
        for bin in 0..<halfSize {
            for frame in 0..<frameCount { column[frame] = magnitudes[frame][bin] }
            column.sort()
            noise[bin] = column[percentileIndex]
        }

        // ---- Gains
        let overSubtraction: Float = 1.2
        let gainFloor: Float = 0.15
        var output = [Float](repeating: 0, count: samples.count)

        var gains = [Float](repeating: 1, count: halfSize)
        var smoothed = [Float](repeating: 1, count: halfSize)

        for frame in 0..<frameCount {
            let magnitude = magnitudes[frame]
            for bin in 0..<halfSize {
                let clean = magnitude[bin] - overSubtraction * noise[bin]
                gains[bin] = magnitude[bin] > 1e-9
                    ? min(1, max(gainFloor, clean / magnitude[bin]))
                    : 1
            }
            // Smooth across frequency: isolated per-bin gains produce the warbling
            // "musical noise" that makes naive spectral subtraction sound worse than the
            // original.
            for bin in 0..<halfSize {
                let low = bin > 0 ? gains[bin - 1] : gains[bin]
                let high = bin < halfSize - 1 ? gains[bin + 1] : gains[bin]
                smoothed[bin] = (low + gains[bin] * 2 + high) / 4
            }

            realp = realParts[frame]
            imagp = imagParts[frame]
            for bin in 0..<halfSize {
                realp[bin] *= smoothed[bin]
                imagp[bin] *= smoothed[bin]
            }

            inverse(setup: setup, realp: &realp, imagp: &imagp, output: &windowed)

            // Overlap-add. Hann at 50% overlap is COLA, so a plain sum reconstructs the
            // amplitude.
            let offset = frame * hop
            for i in 0..<fftSize where offset + i < output.count {
                output[offset + i] += windowed[i]
            }
        }

        // The first and last half-window are only covered by one frame, so they would come
        // back at reduced amplitude. Keep the original samples there instead.
        let head = min(hop, samples.count)
        for i in 0..<head { output[i] = samples[i] }
        let tailStart = max(0, (frameCount - 1) * hop + hop)
        if tailStart < samples.count {
            for i in tailStart..<samples.count { output[i] = samples[i] }
        }

        return output
    }

    // MARK: - FFT plumbing

    private func forward(setup: FFTSetup,
                         input: inout [Float],
                         realp: inout [Float],
                         imagp: inout [Float]) {
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imagBuffer.baseAddress!)
                input.withUnsafeMutableBufferPointer { inputBuffer in
                    inputBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                               capacity: halfSize) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private func inverse(setup: FFTSetup,
                         realp: inout [Float],
                         imagp: inout [Float],
                         output: inout [Float]) {
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imagBuffer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    outputBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                                capacity: halfSize) { packed in
                        vDSP_ztoc(&split, 1, packed, 2, vDSP_Length(halfSize))
                    }
                }
            }
        }
        // `vDSP_fft_zrip` is unnormalised in both directions: a forward-inverse round trip
        // scales by 2N.
        var scale = 1 / Float(2 * fftSize)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(fftSize))
        }
    }
}

// MARK: - File helpers

extension SpeechEnhancer {
    /// Read a mono WAV into memory. Utterances are capped at 28 s, so this is bounded.
    static func readMono(url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        guard length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
            return nil
        }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        return (Array(UnsafeBufferPointer(start: channel, count: count)), format.sampleRate)
    }

    /// Write mono float samples as 16-bit PCM WAV.
    @discardableResult
    static func writeMono(_ samples: [Float], sampleRate: Double, to url: URL) -> Bool {
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
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let destination = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }
}
