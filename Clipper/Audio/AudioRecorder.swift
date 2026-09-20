import AVFoundation
import Combine
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputAvailable
    case noAudioArriving
    case storageFull

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
        case .noInputAvailable:
            return "No microphone is available right now."
        case .noAudioArriving:
            return "The microphone stopped sending audio."
        case .storageFull:
            return "There is not enough free space to keep recording."
        }
    }
}

/// Everything downstream of capture. The recorder knows nothing about databases, models or
/// the UI; it hands finished work to whoever implements this.
protocol RecorderPipeline: AnyObject {
    func recorderDidStartSession(id: UUID, at date: Date)
    func recorderDidEndSession(id: UUID, at date: Date)
    func recorderDidProduceUtterance(_ utterance: PendingUtterance)
    func recorderDidFinishClip(_ clip: Clip, sessionID: UUID)
}

/// The capture engine. A long-lived singleton that exists independently of any view:
/// SwiftUI observes it, never owns it, and a view being torn down cannot stop a recording.
///
/// ## Why there is no start/stop timer
/// Capture is a single continuous `AVAudioEngine` input tap. Segment rotation happens
/// *inside the audio stream*: the writer counts frames, and the moment a buffer crosses
/// the segment boundary it is split — the head closes one file and the tail opens the
/// next. There is no timer to fire late, no restart to fail, and no gap between clips.
/// Wall-clock time is never trusted for segmentation; the audio frames are the clock.
///
/// ## What each tap buffer feeds
/// 1. `SegmentWriter`, at the hardware format, for the rolling buffer of everything heard.
/// 2. `AudioDownmixer` → `SpeechSegmenter`, at 16 kHz mono, for voice activity detection
///    and the speech pipeline.
///
/// Both are read-only consumers of the same detached copy, so the audio thread does one
/// copy and no work.
///
/// ## Threading
/// - `control` queue: session activation, engine start/stop, recovery. All engine mutation.
/// - `writer` queue: rolling-segment file I/O. All `SegmentWriter` access.
/// - `analysis` queue: downmix, FFT, VAD, utterance file writing.
/// - main queue: every `@Published` mutation, and nothing else.
///
/// `writer` and `analysis` never block on `control`; `control` blocks on them with `sync`
/// during teardown and pause only, which is why that direction cannot deadlock.
final class AudioRecorder: NSObject, ObservableObject, AudioSessionObserver {
    static let shared = AudioRecorder()

    weak var pipeline: RecorderPipeline?

    // MARK: - Published state (main queue only)

    @Published private(set) var state: RecorderState = .idle
    /// Identity of the capture session currently running.
    @Published private(set) var sessionID: UUID?
    @Published private(set) var sessionStartedAt: Date?
    /// Start of the rolling segment currently being written, as a real timestamp.
    @Published private(set) var segmentStart: Date?
    /// Length the current rolling segment is being written to.
    @Published private(set) var segmentLength: TimeInterval = 300
    /// Name of the input actually in use, e.g. "iPhone Microphone".
    @Published private(set) var inputName: String?
    @Published private(set) var isUsingBuiltInMic = true
    /// True when another app (Spotify, a game) is playing right now.
    @Published private(set) var otherAudioPlaying = false

    /// Live meter, updated about ten times a second while capturing.
    @Published private(set) var levelDB: Float = -100
    @Published private(set) var snrDB: Float = 0
    @Published private(set) var noiseFloorDB: Float = -55
    /// Total seconds of detected speech in this session.
    @Published private(set) var speechSeconds: TimeInterval = 0
    /// The margin over the noise floor is thin; results from this audio will be weaker.
    @Published private(set) var lowConfidence = false

    /// When the current rolling segment will finish, derived from real segment timing.
    var segmentEnd: Date? {
        segmentStart.map { $0.addingTimeInterval(segmentLength) }
    }

    /// Phase transitions only — what the widget and the Live Activity must react to at once.
    /// Exposed as an explicit publisher rather than `$state` so the published properties can
    /// stay `private(set)`.
    var phasePublisher: AnyPublisher<ClipperPhase, Never> {
        $state.map(\.phase).removeDuplicates().eraseToAnyPublisher()
    }

    /// Coalesced signal for the numbers that change constantly while capturing. Subscribers
    /// are expected to throttle; this fires about ten times a second.
    var meterPublisher: AnyPublisher<Void, Never> {
        Publishers.Merge3($speechSeconds.map { _ in () },
                          $lowConfidence.map { _ in () },
                          $levelDB.map { _ in () })
            .eraseToAnyPublisher()
    }

    // MARK: - Collaborators

    private let session: AudioSessionManager
    private let library: AudioLibrary
    private let settings: AppSettings

    // MARK: - Queues

    private let control = DispatchQueue(label: "app.clipper.recorder.control")
    private let writer = DispatchQueue(label: "app.clipper.recorder.writer", qos: .userInitiated)
    private let analysis = DispatchQueue(label: "app.clipper.recorder.analysis", qos: .userInitiated)

    // MARK: - control-queue state

    private var engine = AVAudioEngine()
    /// The single source of truth for "the user wants capture running".
    private var isCapturing = false
    private var isPaused = false
    private var watchdog: DispatchSourceTimer?
    private var firstBufferTimeout: DispatchWorkItem?
    private var activeSessionID = UUID()
    private var voiceProcessingActive = false

    // MARK: - writer-queue state

    private var segmentWriter: SegmentWriter?
    /// Start timestamp to stamp on the next rolling segment that opens.
    private var pendingStartDate: Date?
    private var activeConfig: ClipperConfig

    // MARK: - analysis-queue state

    private var downmixer: AudioDownmixer? = AudioDownmixer()
    private var segmenter: SpeechSegmenter?

    // MARK: - shared, lock-protected

    private let clockLock = NSLock()
    private var _lastBufferAt: Date?

    private init(session: AudioSessionManager = .shared,
                 library: AudioLibrary = .shared,
                 settings: AppSettings = .shared) {
        self.session = session
        self.library = library
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
                self.publish(.denied)
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

    /// Pause without giving up the audio session, so resuming is immediate. The engine is
    /// genuinely stopped — the UI is never told "listening" while paused.
    func pause() {
        control.async {
            guard self.isCapturing, !self.isPaused else { return }
            self.isPaused = true
            self.cancelFirstBufferTimeout()
            if self.engine.isRunning { self.engine.pause() }
            self.analysis.sync { self.segmenter?.flush() }
            self.writer.sync { self.closeSegment(rotate: false, leftover: nil) }
            self.publish(.paused)
        }
    }

    func resume() {
        control.async {
            guard self.isCapturing, self.isPaused else { return }
            self.isPaused = false
            self.publish(.starting)
            // The audio clock is discontinuous across a pause, so re-anchor rather than
            // let every subsequent utterance timestamp drift by the pause length.
            let resumedAt = Date()
            self.analysis.sync { self.segmenter?.reanchor(audioStart: resumedAt) }
            self.writer.sync { self.pendingStartDate = resumedAt }
            self.restartEngine()
        }
    }

    func togglePause() {
        if state.canResume { resume() } else if state.canPause { pause() }
    }

    /// Clear a sticky error so the main screen returns to Ready.
    func acknowledgeError() {
        publish(.idle)
    }

    /// Pick up a sensitivity change immediately; everything else is picked up at the next
    /// clip boundary.
    func applySensitivityChange() {
        let sensitivity = settings.config.sensitivity
        analysis.async { self.segmenter?.update(sensitivity: sensitivity) }
    }

    // MARK: - Capture lifecycle (control queue)

    private func beginCapture() {
        guard !isCapturing else { return }

        library.bootstrap()
        let config = settings.config

        guard !library.isStorageCritical else {
            publish(.error(RecorderError.storageFull.localizedDescription))
            return
        }

        let sessionIdentifier = UUID()
        let startedAt = Date()

        do {
            try session.activateForCapture(config: config)
            guard session.hasAvailableInput else { throw RecorderError.noInputAvailable }

            writer.sync {
                self.segmentWriter?.discard()
                self.segmentWriter = nil
                self.activeConfig = config
                self.pendingStartDate = startedAt
            }

            analysis.sync {
                if self.downmixer == nil { self.downmixer = AudioDownmixer() }
                let fresh = SpeechSegmenter(directory: self.library.utterancesDirectory,
                                            sensitivity: config.sensitivity)
                fresh.onUtterance = { [weak self] utterance in
                    self?.pipeline?.recorderDidProduceUtterance(utterance)
                }
                fresh.onMetrics = { [weak self] metrics in
                    self?.handleMetrics(metrics)
                }
                fresh.begin(sessionID: sessionIdentifier, audioStart: startedAt)
                self.segmenter = fresh
            }

            try startEngine(config: config)

            isCapturing = true
            isPaused = false
            activeSessionID = sessionIdentifier
            setLastBufferAt(Date())
            startWatchdog()
            armFirstBufferTimeout()

            let input = session.currentInputName
            let builtIn = session.isUsingBuiltInMic
            let others = session.otherAudioPlaying
            publishOnMain {
                self.sessionID = sessionIdentifier
                self.sessionStartedAt = startedAt
                self.segmentLength = config.clipDuration
                self.inputName = input
                self.isUsingBuiltInMic = builtIn
                self.otherAudioPlaying = others
                self.speechSeconds = 0
                self.lowConfidence = false
            }

            Log.audio.notice("Capture session \(sessionIdentifier.uuidString, privacy: .public) started")
            pipeline?.recorderDidStartSession(id: sessionIdentifier, at: startedAt)
        } catch {
            teardown(keepFinalSegment: false, error: error.localizedDescription)
        }
    }

    /// Install the tap and start the engine. Always called on `control`.
    private func startEngine(config: ClipperConfig) throws {
        let input = engine.inputNode

        // Hardware echo cancellation, only if the user opted in. It genuinely reduces the
        // phone's own speaker bleeding into the mic, and it genuinely ducks other apps'
        // audio, which is why it is not the default.
        if config.echoCancellation != voiceProcessingActive {
            do {
                try input.setVoiceProcessingEnabled(config.echoCancellation)
                voiceProcessingActive = config.echoCancellation
            } catch {
                Log.audio.error("Voice processing unavailable: \(error.localizedDescription)")
                voiceProcessingActive = false
            }
        }

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
            // Copy off the audio thread's buffer, then do all real work elsewhere. One
            // copy, two read-only consumers.
            guard let detached = buffer.clipperCopy() else { return }
            self.setLastBufferAt(Date())
            self.writer.async { self.consume(detached) }
            self.analysis.async { self.analyse(detached) }
        }

        engine.prepare()
        try engine.start()
    }

    /// Full teardown. `keepFinalSegment` publishes the partially filled segment as a clip,
    /// which is what the user wants when they tap Stop.
    private func teardown(keepFinalSegment: Bool, error: String?) {
        stopWatchdog()
        cancelFirstBufferTimeout()
        let endedSession = isCapturing ? activeSessionID : nil
        isCapturing = false
        isPaused = false

        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)

        analysis.sync {
            self.segmenter?.flush()
            self.segmenter = nil
            self.downmixer?.reset()
        }

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

        let endedAt = Date()
        let wasDenied: Bool
        if case .denied = state { wasDenied = true } else { wasDenied = false }

        publishOnMain {
            self.segmentStart = nil
            self.sessionID = nil
            self.sessionStartedAt = nil
            self.inputName = nil
            self.levelDB = -100
            self.snrDB = 0
            self.lowConfidence = false
            if let error {
                self.state = .error(error)
            } else if !wasDenied {
                // A permission problem stays visible rather than resetting to Ready.
                self.state = .idle
            }
        }

        if let endedSession {
            Log.audio.notice("Capture session \(endedSession.uuidString, privacy: .public) ended")
            pipeline?.recorderDidEndSession(id: endedSession, at: endedAt)
        }
    }

    // MARK: - Rolling segment pipeline (writer queue)

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
                    directory: library.rollingDirectory,
                    startDate: start,
                    duration: config.clipDuration,
                    quality: config.quality,
                    format: buffer.format
                )
                segmentWriter = newWriter
                publishOnMain {
                    self.segmentStart = start
                    self.segmentLength = config.clipDuration
                    switch self.state {
                    case .starting, .recovering, .interrupted:
                        self.state = .listening(speech: false)
                    default:
                        break
                    }
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

        let boundary = closing.startDate.addingTimeInterval(closing.writtenDuration)
        let sessionIdentifier = activeSessionID
        if let clip = closing.finish() {
            library.adopt(clip)
            pipeline?.recorderDidFinishClip(clip, sessionID: sessionIdentifier)
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
        let nsError = error as NSError
        let message: String
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            message = "Could not write to storage. Free up some space and try again."
        } else {
            message = error.localizedDescription
        }
        library.setStorageError(message)
        control.async { self.teardown(keepFinalSegment: false, error: message) }
    }

    // MARK: - Speech pipeline (analysis queue)

    private func analyse(_ buffer: AVAudioPCMBuffer) {
        guard let downmixer, let segmenter else { return }
        guard let mono = downmixer.convert(buffer) else { return }
        segmenter.process(mono)
    }

    private func handleMetrics(_ metrics: SpeechSegmenter.LiveMetrics) {
        // One tap buffer is ~100 ms, which is also the rate this fires at, so it doubles as
        // the speech-time accumulator.
        let increment: TimeInterval = metrics.isSpeech ? 0.1 : 0
        publishOnMain {
            guard self.state.isCapturingAudio || self.state == .starting else { return }
            self.levelDB = metrics.levelDB
            self.snrDB = metrics.snrDB
            self.noiseFloorDB = metrics.noiseFloorDB
            self.lowConfidence = metrics.lowConfidence
            self.speechSeconds += increment
            if case .listening(let wasSpeech) = self.state, wasSpeech != metrics.isSpeech {
                self.state = .listening(speech: metrics.isSpeech)
            }
        }
    }

    // MARK: - Interruptions and route changes

    func sessionInterruptionBegan() {
        control.async {
            guard self.isCapturing else { return }
            // The system has already stopped our input. Close what we have so the audio
            // captured before the interruption survives as real evidence, then wait to be
            // told we can resume.
            if self.engine.isRunning { self.engine.pause() }
            self.analysis.sync { self.segmenter?.flush() }
            self.writer.sync { self.closeSegment(rotate: false, leftover: nil) }
            guard !self.isPaused else { return }
            self.publish(.interrupted(reason: nil))
        }
    }

    func sessionInterruptionEnded(shouldResume: Bool) {
        control.async {
            guard self.isCapturing else { return }
            // A user pause outlives an interruption: coming back from a phone call must not
            // silently start listening again if the user had paused us first.
            guard !self.isPaused else { return }
            // Attempt recovery either way: `shouldResume` is advisory, and the watchdog
            // would otherwise be the only thing that brings us back.
            self.attemptRecovery()
        }
    }

    func sessionRouteChanged(reason: AVAudioSession.RouteChangeReason) {
        control.async {
            guard self.isCapturing else { return }
            let name = self.session.currentInputName
            let builtIn = self.session.isUsingBuiltInMic
            let others = self.session.otherAudioPlaying
            self.publishOnMain {
                self.inputName = name
                self.isUsingBuiltInMic = builtIn
                self.otherAudioPlaying = others
            }

            guard !self.isPaused else { return }

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
            self.voiceProcessingActive = false
            self.analysis.sync {
                self.segmenter?.flush()
                self.downmixer = AudioDownmixer()
            }
            self.writer.sync {
                self.segmentWriter?.discard()
                self.segmentWriter = nil
                self.pendingStartDate = Date()
            }
            guard !self.isPaused else { return }
            self.publish(.recovering)
            self.attemptRecovery()
        }
    }

    @objc private func handleEngineConfigurationChange(_ note: Notification) {
        control.async {
            guard self.isCapturing, !self.isPaused else { return }
            self.publish(.recovering)
            // Close the current clip: the input format behind it may no longer exist.
            self.writer.sync {
                self.closeSegment(rotate: true, leftover: nil, boundaryFromAudio: false)
            }
            self.restartEngine()
        }
    }

    /// Re-activate the session and bring the engine back. Control queue only.
    private func attemptRecovery() {
        guard isCapturing, !isPaused else { return }
        let config = settings.config
        do {
            try session.activateForCapture(config: config)
            guard session.hasAvailableInput else { throw RecorderError.noInputAvailable }
            publish(.recovering)
            let resumedAt = Date()
            analysis.sync { self.segmenter?.reanchor(audioStart: resumedAt) }
            writer.sync { if self.pendingStartDate == nil { self.pendingStartDate = resumedAt } }
            restartEngine()
        } catch {
            // Stay in `interrupted`, not `error`: the watchdog will keep trying, and the
            // UI keeps telling the truth about what is happening.
            publish(.interrupted(reason: nil))
        }
    }

    private func restartEngine() {
        do {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try startEngine(config: settings.config)
            setLastBufferAt(Date())
            armFirstBufferTimeout()
        } catch {
            publish(.interrupted(reason: error.localizedDescription))
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
        guard isCapturing, !isPaused else { return }

        if !engine.isRunning {
            attemptRecovery()
            return
        }

        // Engine claims to be running but no buffers are arriving: a stalled input.
        if let last = lastBufferAt(), Date().timeIntervalSince(last) > 6 {
            Log.audio.error("No audio for 6s with the engine running — restarting")
            restartEngine()
        }
    }

    /// Control queue only. Cancellation is an optimisation — the work item is idempotent
    /// and re-checks `lastBufferAt` before doing anything.
    private func armFirstBufferTimeout() {
        cancelFirstBufferTimeout()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCapturing, !self.isPaused else { return }
            if let last = self.lastBufferAt(), Date().timeIntervalSince(last) > 4 {
                self.publish(.interrupted(reason: "No audio is arriving from the microphone"))
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
