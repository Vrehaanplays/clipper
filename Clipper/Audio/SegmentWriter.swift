import AVFoundation
import Foundation

enum SegmentWriterError: LocalizedError {
    case couldNotAllocateBuffer
    case unsupportedBufferFormat

    var errorDescription: String? {
        switch self {
        case .couldNotAllocateBuffer: return "Ran out of memory while writing audio."
        case .unsupportedBufferFormat: return "The microphone returned an audio format Clipper cannot encode."
        }
    }
}

/// Result of handing a buffer to a writer.
enum SegmentWriteResult {
    /// Still filling this segment.
    case continued
    /// The segment reached its exact target length. The payload is the tail of the last
    /// buffer, which belongs to the *next* segment — handing it straight on is what makes
    /// rotation gapless and sample-accurate.
    case completed(leftover: AVAudioPCMBuffer?)
}

/// Writes exactly one segment: AAC in an M4A container, opened at a `.part` path and
/// atomically moved to its final `.m4a` name only once the container is finalized.
///
/// Not thread-safe by design — it is confined to the recorder writer queue.
final class SegmentWriter {
    let startDate: Date
    let format: AVAudioFormat
    let partialURL: URL
    let finalURL: URL

    private var file: AVAudioFile?
    private let targetFrames: AVAudioFramePosition
    private var framesWritten: AVAudioFramePosition = 0

    /// Duration of what has actually been committed to the file.
    var writtenDuration: TimeInterval {
        format.sampleRate > 0 ? Double(framesWritten) / format.sampleRate : 0
    }

    init(directory: URL,
         startDate: Date,
         duration: TimeInterval,
         quality: AudioQuality,
         format: AVAudioFormat) throws {

        guard format.sampleRate > 0, format.channelCount > 0, !format.isInterleaved,
              format.commonFormat == .pcmFormatFloat32 else {
            throw SegmentWriterError.unsupportedBufferFormat
        }

        self.startDate = startDate
        self.format = format
        self.targetFrames = AVAudioFramePosition((duration * format.sampleRate).rounded())

        let base = Clip.filename(for: startDate)
        self.finalURL = directory
            .appendingPathComponent(base)
            .appendingPathExtension(Clip.finalExtension)
        self.partialURL = directory
            .appendingPathComponent(base)
            .appendingPathExtension(Clip.finalExtension)
            .appendingPathExtension(Clip.partialExtension)

        // If a previous run left debris at either path, clear it first.
        try? FileManager.default.removeItem(at: partialURL)

        let channels = Int(format.channelCount)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: quality.bitRate(forChannels: channels),
        ]

        // The processing format is float32 non-interleaved at the same rate and channel
        // count as the tap buffers, so no conversion happens on our side; AVAudioFile
        // drives the hardware AAC encoder.
        //
        // Not every AAC encoder accepts an explicit bit rate at every sample rate — the
        // Simulator's rejects several the hardware encoder takes without complaint. A
        // refused bit rate is no reason to lose the recording, so retry and let the
        // encoder choose; the clip is slightly larger, and it exists.
        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(forWriting: partialURL,
                                      settings: settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        } catch {
            Log.audio.notice("Encoder refused the requested bit rate; using its default")
            settings.removeValue(forKey: AVEncoderBitRateKey)
            newFile = try AVAudioFile(forWriting: partialURL,
                                      settings: settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        }

        // `AVAudioFile.write(from:)` raises an Objective-C exception on a format mismatch,
        // and that cannot be caught from Swift — it would take the app down mid-recording.
        // Verify the match up front instead, so an exotic input device becomes a clean,
        // reported error rather than a crash.
        guard newFile.processingFormat == format else {
            try? FileManager.default.removeItem(at: partialURL)
            throw SegmentWriterError.unsupportedBufferFormat
        }

        self.file = newFile
    }

    // MARK: - Writing

    func write(_ buffer: AVAudioPCMBuffer) throws -> SegmentWriteResult {
        guard let file, buffer.frameLength > 0 else { return .continued }

        let remaining = targetFrames - framesWritten
        guard remaining > 0 else { return .completed(leftover: buffer) }

        let incoming = AVAudioFramePosition(buffer.frameLength)

        if incoming < remaining {
            try file.write(from: buffer)
            framesWritten += incoming
            return .continued
        }

        if incoming == remaining {
            try file.write(from: buffer)
            framesWritten += incoming
            return .completed(leftover: nil)
        }

        // The boundary falls inside this buffer: split it so the segment is exactly the
        // requested length and not one frame of audio is dropped.
        let headCount = AVAudioFrameCount(remaining)
        guard
            let head = buffer.clipperSlice(from: 0, count: headCount),
            let tail = buffer.clipperSlice(from: headCount, count: buffer.frameLength - headCount)
        else {
            throw SegmentWriterError.couldNotAllocateBuffer
        }

        try file.write(from: head)
        framesWritten += remaining
        return .completed(leftover: tail)
    }

    // MARK: - Completion

    /// Close the container and publish the file under its final name.
    /// Returns `nil` if there was nothing worth keeping.
    func finish() -> Clip? {
        // Releasing the AVAudioFile flushes the encoder and writes the MPEG-4 index.
        // Until this happens the `.part` file is not playable, which is exactly why
        // an unfinished recording can never be mistaken for a clip.
        file = nil

        let fm = FileManager.default
        guard framesWritten > 0 else {
            try? fm.removeItem(at: partialURL)
            return nil
        }

        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: partialURL, to: finalURL)
            // Stamp the real start time so chronological sorting works off metadata
            // rather than off the filename.
            try? fm.setAttributes([.creationDate: startDate], ofItemAtPath: finalURL.path)

            let size = (try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Clip(url: finalURL,
                        startDate: startDate,
                        duration: writtenDuration,
                        byteSize: Int64(size))
        } catch {
            return nil
        }
    }

    /// Abandon this segment without publishing it.
    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: partialURL)
    }
}

// MARK: - Buffer helpers

extension AVAudioPCMBuffer {
    /// Copy a frame range into a fresh buffer. Only valid for non-interleaved float32,
    /// which is what an input-node tap always produces.
    func clipperSlice(from offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0,
              offset + count <= frameLength,
              !format.isInterleaved,
              let source = floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let destination = out.floatChannelData
        else { return nil }

        out.frameLength = count
        let bytes = Int(count) * MemoryLayout<Float>.size
        for channel in 0..<Int(format.channelCount) {
            memcpy(destination[channel], source[channel].advanced(by: Int(offset)), bytes)
        }
        return out
    }

    /// Detach a tap buffer from the audio thread's memory so it can be written later.
    func clipperCopy() -> AVAudioPCMBuffer? {
        clipperSlice(from: 0, count: frameLength)
    }
}
