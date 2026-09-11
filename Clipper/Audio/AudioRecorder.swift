import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputAvailable
    case noAudioArriving

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
        case .noInputAvailable:
            return "No microphone is available right now."
        case .noAudioArriving:
            return "The microphone stopped sending audio."
        }
    }
}

/// The recording engine. A long-lived singleton that exists independently of any view:
/// SwiftUI observes it, never owns it, and a view being torn down cannot stop a recording.
///
/// ## Why there is no start/stop timer
/// Capture is a single continuous `AVAudioEngine` input tap. Segment rotation happens
/// *inside the audio stream*: the writer counts frames, and the moment a buffer crosses
/// the 5-minute boundary it is split — the head closes one file and the tail opens the
/// next. There is no timer to fire late, no restart to fail, and no gap between clips.
/// Wall-clock time is never trusted for segmentation; the audio frames are the clock.
///
/// ## Threading
/// - `control` queue: session activation, engine start/stop, recovery. All engine mutation.
/// - `writer` queue: file I/O and rotation. All `SegmentWriter` access.
/// - main queue: every `@Published` mutation, and nothing else.
///
/// Tap callbacks copy their buffer and hop to `writer`, so no file I/O ever runs on the
/// audio thread.
final class AudioRecorder: NSObject, ObservableObject, AudioSessionObserver {
    static let shared = AudioRecorder()

    // MARK: - Published state (main queue only)

    @Published private(set) var state: RecorderState = .idle
    /// Start of the segment currently being written, as a real timestamp.
    @Published private(set) var segmentStart: Date?
    /// Length the current segment is being written to.
    @Published private(set) var segmentLength: TimeInterval = 300
    /// Name of the input actually in use, e.g. "iPhone Microphone".
    @Published private(set) var inputName: String?

    /// When the current segment will finish, derived from real segment timing.
    var segmentEnd: Date? {
        segmentStart.map { $0.addingTimeInterval(segmentLength) }
    }

    // MARK: - Collaborators

    private let session: AudioSessionManager
    private let store: ClipStore
    private let settings: AppSettings

    // MARK: - Queues

    private let control = DispatchQueue(label: "app.clipper.recorder.control")
    private let writer = DispatchQueue(label: "app.clipper.recorder.writer", qos: .userInitiated)

    // MARK: - control-queue state

    private var engine = AVAudioEngine()
    /// The single source of truth for "the user wants capture running".
    private var isCapturing = false
    private var watchdog: DispatchSourceTimer?
    private var firstBufferTimeout: DispatchWorkItem?

    // MARK: - writer-queue state

    private var segmentWriter: SegmentWriter?
    /// Start timestamp to stamp on the next segment that opens.
    private var pendingStartDate: Date?
    private var activeConfig: RecordingConfig

    // MARK: - shared, lock-protected

    private let clockLock = NSLock()
    private var _lastBufferAt: Date?

    private init(session: AudioSessionManager = .shared,
                 store: ClipStore = .shared,
                 settings: AppSettings = .shared) {
        self.session = session
        self.store = store
        self.settings = settings
        // Reads the parameter, not `self`, so this is safe before `super.init()`.
        self.activeConfig = settings.config
        self.segmentLength = settings.config.clipDuration
        super.init()

        session.observer = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    // MARK: - Public API

    func toggle() {
        if state.isActive { stop() } else { start() }
    }

    /// Ask for permission if needed, then begin capture.
    func start() {
        guard !state.isActive else { return }
        publish(.starting)
        session.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publish(.error(RecorderError.microphoneDenied.localizedDescription))
                return
            }
            self.control.async { self.beginCapture() }
        }
    }

    func stop() {
        guard state.isActive else { return }
        publish(.stopping)
        control.async { self.teardown(keepFinalSegment: true, error: nil) }
    }

    /// Clear a sticky error so the main screen returns to Ready.
    func acknowledgeError() {
        publish(.idle)
    }

    // MARK: - Capture lifecycle (control queue)

    private func beginCapture() {
        guard !isCapturing else { return }

        store.bootstrap()
        let config = settings.config

        do {
            try session.activateForCapture()
            guard session.hasAvailableInput else { throw RecorderError.noInputAvailable }

            writer.sync {
                self.segmentWriter?.discard()
                self.segmentWriter = nil
                self.activeConfig = config
                self.pendingStartDate = Date()
            }

            try startEngine()

            isCapturing = true
            setLastBufferAt(Date())
            startWatchdog()
            armFirstBufferTimeout()
            let input = session.currentInputName
            publishOnMain { self.segmentLength = config.clipDuration; self.inputName = input }
        } catch {
            teardown(keepFinalSegment: false, error: error.localizedDescription)
        }
    }

    /// Install the tap and start the engine. Always called on `control`.
    private func startEngine() throws {
        let input = engine.inputNode
        // Reading the format also forces the input node to be instantiated. A zero-rate
        // format means there is genuinely no usable input; installing a tap in that state
        // would trap, so bail out cleanly instead.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noInputAvailable
        }

        input.removeTap(onBus: 0)
        // `format: nil` adopts the node's own format, which avoids a format-mismatch trap
        // after a route change. The writer is created from the first buffer that arrives,
        // so whatever the hardware gives us is what we encode.
        input.installTap(onBus: 0, bufferSize: 4_800, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy off the audio thread's buffer, then do all real work elsewhere.
            guard let detached = buffer.clipperCopy() else { return }
            self.setLastBufferAt(Date())
            self.writer.async { self.consume(detached) }
        }

        engine.prepare()
        try engine.start()
    }

    /// Full teardown. `keepFinalSegment` publishes the partially filled segment as a clip,
    /// which is what the user wants when they tap Stop.
    private func teardown(keepFinalSegment: Bool, error: String?) {
        stopWatchdog()
        cancelFirstBufferTimeout()
        isCapturing = false

        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)

        writer.sync {
            if keepFinalSegment {
                self.closeSegment(rotate: false, leftover: nil)
            } else {
                self.segmentWriter?.discard()
                self.segmentWriter = nil
            }
            self.pendingStartDate = nil
        }

        session.deactivate()

        publishOnMain {
            self.segmentStart = nil
            self.inputName = nil
            self.state = error.map { RecorderState.error($0) } ?? .idle
        }
    }

    // MARK: - Segment pipeline (writer queue)

    private func consume(_ buffer: AVAudioPCMBuffer) {
        do {
            // A route change can hand us a different sample rate or channel count. The
            // current container cannot absorb that, so close it and open a fresh one.
            if let current = segmentWriter, current.format != buffer.format {
                closeSegment(rotate: true, leftover: nil, boundaryFromAudio: false)
            }

            if segmentWriter == nil {
                let start = pendingStartDate ?? Date()
                pendingStartDate = nil
                let config = activeConfig
                let newWriter = try SegmentWriter(
                    directory: store.clipsDirectory,
                    startDate: start,
                    duration: config.clipDuration,
                    quality: config.quality,
                    format: buffer.format
                )
                segmentWriter = newWriter
                publishOnMain {
                    self.segmentStart = start
                    self.segmentLength = config.clipDuration
                    if self.state != .recording { self.state = .recording }
                }
            }

            guard let active = segmentWriter else { return }

            switch try active.write(buffer) {
            case .continued:
                break
            case .completed(let leftover):
                closeSegment(rotate: true, leftover: leftover)
            }
        } catch {
            handleWriteFailure(error)
        }
    }

    /// Finalize the open segment and, when rotating, immediately open the next one.
    /// Writer queue only.
    ///
    /// - Parameter boundaryFromAudio: when true the next segment is timestamped from the
    ///   audio boundary, so consecutive clips are contiguous to the sample. When false
    ///   (recovery, format change) there is a real gap, so wall-clock time is used.
    private func closeSegment(rotate: Bool,
                              leftover: AVAudioPCMBuffer?,
                              boundaryFromAudio: Bool = true) {
        guard let closing = segmentWriter else {
            if rotate, pendingStartDate == nil { pendingStartDate = Date() }
            return
        }
        segmentWriter = nil

        publishOnMain {
            if self.state == .recording { self.state = .finalizing }
        }

        let boundary = closing.startDate.addingTimeInterval(closing.writtenDuration)
        if let clip = closing.finish() {
            store.adopt(clip)
        }

        guard rotate else { return }

        // Pick up any settings change exactly at a clip boundary, never mid-segment.
        activeConfig = settings.config
        pendingStartDate = boundaryFromAudio ? boundary : Date()

        if let leftover {
            // Re-entering `consume` opens the next segment in the same turn of the queue,
            // so there is no silent window between clips.
            consume(leftover)
        }
        // With no leftover, the next tap buffer (~100 ms away) opens the next segment.
    }

    private func handleWriteFailure(_ error: Error) {
        segmentWriter?.discard()
        segmentWriter = nil
        let message: String
        if (error as NSError).domain == NSCocoaErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain {
            message = "Could not write to storage. Free up some space and try again."
        } else {
            message = error.localizedDescription
        }
        store.setStorageError(message)
        control.async { self.teardown(keepFinalSegment: false, error: message) }
    }

    // MARK: - Interruptions and route changes

    func sessionInterruptionBegan() {
        control.async {
            guard self.isCapturing else { return }
            // The system has already stopped our input. Close what we have so the audio
            // captured before the interruption survives as a real, playable clip, then
            // wait to be told we can resume.
            if self.engine.isRunning { self.engine.pause() }
            self.writer.sync { self.closeSegment(rotate: false, leftover: nil) }
            self.publish(.interrupted)
        }
    }

    func sessionInterruptionEnded(shouldResume: Bool) {
        control.async {
            guard self.isCapturing else { return }
            // Attempt recovery either way: `shouldResume` is advisory, and the watchdog
            // would otherwise be the only thing that brings us back.
            self.attemptRecovery()
        }
    }

    func sessionRouteChanged(reason: AVAudioSession.RouteChangeReason) {
        control.async {
            guard self.isCapturing else { return }
            let name = self.session.currentInputName
            self.publishOnMain { self.inputName = name }

            switch reason {
            case .oldDeviceUnavailable, .newDeviceAvailable, .override,
                 .routeConfigurationChange, .categoryChange:
                // The engine may have been stopped underneath us, or the input format may
                // have changed. `.AVAudioEngineConfigurationChange` usually follows, but
                // recovering here too costs nothing and closes the gap sooner.
                if !self.engine.isRunning { self.attemptRecovery() }
            default:
                break
            }
        }
    }

    func sessionMediaServicesWereReset() {
        control.async {
            guard self.isCapturing else { return }
            // Every audio object is invalid, including the engine itself. Rebuild it.
            self.engine = AVAudioEngine()
            self.writer.sync {
                self.segmentWriter?.discard()
                self.segmentWriter = nil
                self.pendingStartDate = Date()
            }
            self.publish(.starting)
            self.attemptRecovery()
        }
    }

    @objc private func handleEngineConfigurationChange(_ note: Notification) {
        control.async {
            guard self.isCapturing else { return }
            self.publish(.starting)
            // Close the current clip: the input format behind it may no longer exist.
            self.writer.sync {
                self.closeSegment(rotate: true, leftover: nil, boundaryFromAudio: false)
            }
            self.restartEngine()
        }
    }

    /// Re-activate the session and bring the engine back. Control queue only.
    private func attemptRecovery() {
        guard isCapturing else { return }
        do {
            try session.activateForCapture()
            guard session.hasAvailableInput else { throw RecorderError.noInputAvailable }
            publish(.starting)
            writer.sync { if self.pendingStartDate == nil { self.pendingStartDate = Date() } }
            restartEngine()
        } catch {
            // Stay in `interrupted`, not `error`: the watchdog will keep trying, and the
            // UI keeps telling the truth about what is happening.
            publish(.interrupted)
        }
    }

    private func restartEngine() {
        do {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try startEngine()
            setLastBufferAt(Date())
            armFirstBufferTimeout()
        } catch {
            publish(.interrupted)
        }
    }

    // MARK: - Watchdog
    //
    // Not the segmentation mechanism — rotation is driven entirely by audio frames. This
    // is purely a recovery net for the cases where the system never sends us an
    // interruption-ended notification, or where the engine dies silently. It fires rarely
    // and does no work when everything is healthy.

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkHealth() {
        guard isCapturing else { return }

        if !engine.isRunning {
            attemptRecovery()
            return
        }

        // Engine claims to be running but no buffers are arriving: a stalled input.
        if let last = lastBufferAt(), Date().timeIntervalSince(last) > 6 {
            restartEngine()
        }
    }

    /// Control queue only. Cancellation is an optimisation — the work item is idempotent
    /// and re-checks `lastBufferAt` before doing anything.
    private func armFirstBufferTimeout() {
        cancelFirstBufferTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCapturing else { return }
            if let last = self.lastBufferAt(), Date().timeIntervalSince(last) > 4 {
                self.publish(.interrupted)
            }
        }
        firstBufferTimeout = item
        control.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Control queue only.
    private func cancelFirstBufferTimeout() {
        firstBufferTimeout?.cancel()
        firstBufferTimeout = nil
    }

    // MARK: - Plumbing

    private func setLastBufferAt(_ date: Date) {
        clockLock.lock(); _lastBufferAt = date; clockLock.unlock()
    }

    private func lastBufferAt() -> Date? {
        clockLock.lock(); defer { clockLock.unlock() }; return _lastBufferAt
    }

    private func publish(_ newState: RecorderState) {
        publishOnMain { self.state = newState }
    }

    private func publishOnMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
