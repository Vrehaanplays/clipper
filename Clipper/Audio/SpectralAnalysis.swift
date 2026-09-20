import Accelerate
import Foundation

/// One analysis window's worth of measurements. Everything the VAD, the confidence score
/// and the stored audio-quality metadata are derived from.
struct SpectralFrame: Equatable {
    /// Linear RMS amplitude, 0...1-ish.
    var rms: Float
    var peak: Float
    /// `20*log10(rms)`, clamped to -100 dB.
    var levelDB: Float
    /// Running estimate of the room's noise floor in dB.
    var noiseFloorDB: Float
    /// How far this window sits above the noise floor. The primary VAD signal.
    var snrDB: Float
    /// Spectral flatness (Wiener entropy), 0...1. Tonal/voiced audio is low; hiss and
    /// broadband noise are high. This is what separates a voice from a fan or a hiss.
    var flatness: Float
    /// Spectral centroid in Hz — the "brightness". Speech sits low; cymbals and UI
    /// clicks sit high.
    var centroidHz: Float
    /// Fraction of the energy inside the 300–3400 Hz telephony band.
    var voiceBandRatio: Float

    static let silent = SpectralFrame(rms: 0, peak: 0, levelDB: -100, noiseFloorDB: -60,
                                      snrDB: 0, flatness: 1, centroidHz: 0, voiceBandRatio: 0)
}

/// Tracks the noise floor with minimum statistics: the floor is the minimum observed level
/// over a sliding window, which needs no help from the VAD and therefore cannot get stuck
/// in a feedback loop with it.
///
/// Four rotating sub-window minima give an O(1) sliding minimum over ~2 seconds.
final class NoiseTracker {
    private var minima: [Float]
    private let framesPerSubWindow: Int
    private var index = 0
    private var counter = 0

    /// Minimum statistics systematically underestimates the true floor; +3 dB is the
    /// standard bias correction.
    private let biasCorrectionDB: Float = 3

    private(set) var noiseFloorDB: Float = -55

    init(subWindows: Int = 4, framesPerSubWindow: Int = 32) {
        self.minima = Array(repeating: .greatestFiniteMagnitude, count: max(2, subWindows))
        self.framesPerSubWindow = max(4, framesPerSubWindow)
    }

    func reset() {
        for i in minima.indices { minima[i] = .greatestFiniteMagnitude }
        index = 0
        counter = 0
        noiseFloorDB = -55
    }

    func update(levelDB: Float) -> Float {
        minima[index] = min(minima[index], levelDB)
        counter += 1
        if counter >= framesPerSubWindow {
            counter = 0
            index = (index + 1) % minima.count
            minima[index] = .greatestFiniteMagnitude
        }

        let observed = minima.filter { $0 < .greatestFiniteMagnitude }.min() ?? levelDB
        let target = observed + biasCorrectionDB
        // Rise slowly (a new steady noise source), fall quickly (the room went quiet).
        let rate: Float = target > noiseFloorDB ? 0.02 : 0.2
        noiseFloorDB += rate * (target - noiseFloorDB)
        noiseFloorDB = min(max(noiseFloorDB, -80), -10)
        return noiseFloorDB
    }
}

/// Windowed FFT analysis of a mono stream, producing one `SpectralFrame` per hop.
///
/// Deliberately allocation-free after `init`: the buffers are raw pointers rather than
/// Swift arrays, which also avoids exclusive-access trouble with `DSPSplitComplex`.
/// Runs on the analysis queue, never on the audio render thread.
final class SpectralAnalyzer {
    let fftSize: Int
    let hop: Int
    let sampleRate: Double

    private let halfSize: Int
    private let log2n: vDSP_Length
    /// `nil` only if the FFT setup could not be allocated, in which case the analyzer
    /// degrades to level-only features rather than failing.
    private let setup: FFTSetup?

    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    /// Carry buffer: samples that arrived but did not complete a window.
    private let carry: UnsafeMutablePointer<Float>
    private var carried = 0

    private let noise = NoiseTracker()

    init(sampleRate: Double, fftSize: Int = 512, hop: Int = 256) {
        // Power of two, so radix-2 applies.
        let size = max(64, 1 << Int(log2(Double(fftSize)).rounded()))
        self.fftSize = size
        self.hop = max(32, min(hop, size))
        self.sampleRate = sampleRate
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realp = .allocate(capacity: halfSize)
        imagp = .allocate(capacity: halfSize)
        magnitudes = .allocate(capacity: halfSize)
        carry = .allocate(capacity: size * 2)

        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed.initialize(repeating: 0, count: size)
        realp.initialize(repeating: 0, count: halfSize)
        imagp.initialize(repeating: 0, count: halfSize)
        magnitudes.initialize(repeating: 0, count: halfSize)
        carry.initialize(repeating: 0, count: size * 2)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        window.deallocate()
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
        carry.deallocate()
    }

    func reset() {
        carried = 0
        noise.reset()
    }

    var noiseFloorDB: Float { noise.noiseFloorDB }

    /// Feed mono samples. `onFrame` fires once per completed hop, in order.
    func process(_ samples: UnsafePointer<Float>, count: Int, onFrame: (SpectralFrame) -> Void) {
        var offset = 0
        while offset < count {
            let want = fftSize - carried
            let take = min(want, count - offset)
            (carry + carried).update(from: samples + offset, count: take)
            carried += take
            offset += take

            guard carried == fftSize else { return }

            onFrame(analyzeCarry())

            // Slide by one hop, keeping the overlap.
            let keep = fftSize - hop
            if keep > 0 {
                memmove(carry, carry + hop, keep * MemoryLayout<Float>.size)
            }
            carried = keep
        }
    }

    // MARK: - One window

    private func analyzeCarry() -> SpectralFrame {
        var rms: Float = 0
        vDSP_rmsqv(carry, 1, &rms, vDSP_Length(fftSize))
        var peak: Float = 0
        vDSP_maxmgv(carry, 1, &peak, vDSP_Length(fftSize))

        let levelDB = SpectralAnalyzer.amplitudeToDB(rms)
        let floorDB = noise.update(levelDB: levelDB)
        let snr = levelDB - floorDB

        guard let setup else {
            return SpectralFrame(rms: rms, peak: peak, levelDB: levelDB, noiseFloorDB: floorDB,
                                 snrDB: snr, flatness: 0.5, centroidHz: 0, voiceBandRatio: 0.5)
        }

        vDSP_vmul(carry, 1, window, 1, windowed, 1, vDSP_Length(fftSize))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        // Real-to-complex packing: N real samples become N/2 interleaved complex pairs.
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(halfSize))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // Squared magnitudes. `zrip` packs Nyquist into imagp[0]; that single bin is not
        // worth special-casing for these features.
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(halfSize))

        let features = spectralFeatures()

        return SpectralFrame(rms: rms,
                             peak: peak,
                             levelDB: levelDB,
                             noiseFloorDB: floorDB,
                             snrDB: snr,
                             flatness: features.flatness,
                             centroidHz: features.centroid,
                             voiceBandRatio: features.voiceBand)
    }

    private func spectralFeatures() -> (flatness: Float, centroid: Float, voiceBand: Float) {
        let epsilon: Float = 1e-12
        let binWidth = Float(sampleRate) / Float(fftSize)
        // Skip bin 0: DC carries no information about speech and dominates when the mic
        // has any offset.
        let lowBin = max(1, Int((300 / binWidth).rounded(.down)))
        let highBin = min(halfSize - 1, Int((3400 / binWidth).rounded(.up)))

        var total: Float = 0
        var voiceBand: Float = 0
        var weighted: Float = 0
        var logSum: Float = 0
        var counted = 0

        for bin in 1..<halfSize {
            let power = magnitudes[bin]
            total += power
            weighted += power * (Float(bin) * binWidth)
            logSum += log(power + epsilon)
            counted += 1
            if bin >= lowBin && bin <= highBin { voiceBand += power }
        }

        guard total > epsilon, counted > 0 else { return (1, 0, 0) }

        let arithmeticMean = total / Float(counted)
        let geometricMean = exp(logSum / Float(counted))
        let flatness = min(1, max(0, geometricMean / (arithmeticMean + epsilon)))

        return (flatness, weighted / total, voiceBand / total)
    }

    static func amplitudeToDB(_ amplitude: Float) -> Float {
        amplitude <= 1e-7 ? -100 : max(-100, 20 * log10(amplitude))
    }
}
