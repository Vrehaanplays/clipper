import AVFoundation
import Foundation

/// Converts whatever the microphone hands us (typically 48 kHz, one or two channels,
/// float32) into the one format the analysis and transcription path wants: 16 kHz mono
/// float32.
///
/// `AVAudioConverter` rather than hand-rolled decimation, because dropping samples to get
/// from 48 kHz to 16 kHz aliases everything above 8 kHz down into the speech band — which
/// is exactly where the VAD and the transcriber are looking. The converter applies the
/// anti-alias filter for us.
///
/// One instance per capture session, rebuilt whenever the input format changes.
final class AudioDownmixer {
    /// 16 kHz mono float32 — the sample rate `SFSpeechRecognizer` wants, and enough
    /// bandwidth for the 300–3400 Hz analysis band with headroom.
    static let targetSampleRate: Double = 16_000

    let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init?() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1,
                                         interleaved: false) else { return nil }
        self.outputFormat = format
    }

    /// True when the next call would have to rebuild the converter.
    func needsRebuild(for format: AVAudioFormat) -> Bool {
        inputFormat != format
    }

    func reset() {
        converter?.reset()
    }

    /// Returns `nil` if the conversion could not be set up or produced nothing. Callers
    /// treat that as "no analysis for this buffer", never as an error worth stopping for:
    /// the rolling buffer is still being written from the original stream.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }

        if inputFormat != buffer.format || converter == nil {
            guard let fresh = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                return nil
            }
            // Downmix rather than take channel 0, so a two-mic capture keeps both.
            fresh.downmix = true
            fresh.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            converter = fresh
            inputFormat = buffer.format
        }

        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        // Headroom: the converter's filter delay means output length is not exactly
        // input * ratio.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var conversionError: NSError?
        let fill: AVAudioConverterInputBlock = { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        // One call per buffer, deliberately. The rate converter holds a filter's worth of
        // frames back — the first buffer comes out roughly 15% short at 48 kHz → 16 kHz —
        // but it keeps that state across calls, so the remainder arrives with the next
        // buffer and a continuous stream loses nothing. Pulling harder here cannot produce
        // those frames early; it would need input that has not been captured yet.
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: fill)

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream:
            return nil
        case .error:
            Log.audio.error("Downmix failed: \(conversionError?.localizedDescription ?? "unknown")")
            // Force a rebuild next time; a route change often lands here.
            self.converter = nil
            self.inputFormat = nil
            return nil
        @unknown default:
            return nil
        }
    }
}
