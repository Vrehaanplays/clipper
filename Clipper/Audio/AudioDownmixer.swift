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

        // The rate converter holds frames back in its own filter, so one call returns
        // noticeably fewer than input * ratio — about 15% short at 48 kHz → 16 kHz. Dropping
        // that remainder would punch a hole in the analysis stream on every buffer, so keep
        // pulling until the converter has nothing left for the input it was given.
        while output.frameLength < capacity {
            guard let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                 frameCapacity: capacity - output.frameLength)
            else { break }

            let status = converter.convert(to: scratch, error: &conversionError, withInputFrom: fill)

            if status == .error {
                Log.audio.error("Downmix failed: \(conversionError?.localizedDescription ?? "unknown")")
                // Force a rebuild next time; a route change often lands here.
                self.converter = nil
                self.inputFormat = nil
                return nil
            }

            append(scratch, to: output)
            if scratch.frameLength == 0 || status != .haveData { break }
        }

        return output.frameLength > 0 ? output : nil
    }

    /// Copy `source`'s frames onto the end of `destination`. Both are float32
    /// non-interleaved in `outputFormat`, so this is a per-channel memcpy.
    private func append(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        guard source.frameLength > 0,
              let from = source.floatChannelData,
              let into = destination.floatChannelData else { return }

        let room = destination.frameCapacity - destination.frameLength
        let frames = min(source.frameLength, room)
        guard frames > 0 else { return }

        for channel in 0..<Int(destination.format.channelCount) {
            into[channel].advanced(by: Int(destination.frameLength))
                .update(from: from[channel], count: Int(frames))
        }
        destination.frameLength += frames
    }
}
