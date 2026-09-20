import AVFoundation
import Foundation

/// Everything the recorder needs to know about the system taking the mic away.
protocol AudioSessionObserver: AnyObject {
    func sessionInterruptionBegan()
    func sessionInterruptionEnded(shouldResume: Bool)
    func sessionRouteChanged(reason: AVAudioSession.RouteChangeReason)
    func sessionMediaServicesWereReset()
}

/// The category/mode/options decision, extracted from `AVAudioSession` so it can be unit
/// tested without a device. This is the part of the audio configuration that is pure
/// policy, and the part most likely to be got wrong.
struct AudioSessionPlan: Equatable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    /// Pin the input to the iPhone's own microphone rather than whatever is attached.
    let preferBuiltInMic: Bool
    /// Ask `AVAudioEngine` for hardware echo cancellation / AGC / noise suppression.
    let voiceProcessing: Bool

    /// The capture plan.
    ///
    /// - `.playAndRecord` for the whole capture lifetime, so playing a clip back never
    ///   needs a category switch (a switch mid-capture tears the engine down).
    /// - `.mixWithOthers` is the **only** public way to let Spotify or a game keep playing
    ///   while we record. Without it, activating the session interrupts them.
    /// - `.defaultToSpeaker` because `.playAndRecord` otherwise routes playback to the
    ///   earpiece, which makes clip playback sound broken.
    /// - No Bluetooth options at all: Clipper is specified to use the built-in microphone,
    ///   and offering a Bluetooth input would silently change what it can hear.
    /// - `.voiceChat` mode only when the user opts into echo cancellation, because that
    ///   mode ducks or interrupts other apps' audio, which defeats the point.
    static func capture(for config: ClipperConfig) -> AudioSessionPlan {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        if config.letOtherAppsPlay {
            options.insert(.mixWithOthers)
        }
        return AudioSessionPlan(
            category: .playAndRecord,
            mode: config.echoCancellation ? .voiceChat : .default,
            options: options,
            preferBuiltInMic: true,
            voiceProcessing: config.echoCancellation
        )
    }

    /// Playback with no capture running.
    static let playback = AudioSessionPlan(
        category: .playback,
        mode: .default,
        options: [],
        preferBuiltInMic: false,
        voiceProcessing: false
    )
}

/// Sole owner of `AVAudioSession`. Nothing else in the app configures it.
final class AudioSessionManager: NSObject {
    static let shared = AudioSessionManager()

    weak var observer: AudioSessionObserver?

    private let session = AVAudioSession.sharedInstance()
    private let notifications = NotificationCenter.default

    /// The plan last applied, so Diagnostics can show what is actually in force rather
    /// than what we intended.
    private(set) var activePlan: AudioSessionPlan?

    private override init() {
        super.init()
        registerForNotifications()
    }

    // MARK: - Permission

    var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Asks once, normally, through the system prompt. Completion is always on the main queue.
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Activation

    /// Configure and activate for capture. Paired with the `audio` background mode, this is
    /// what keeps recording alive with the app backgrounded and the screen off.
    func activateForCapture(config: ClipperConfig) throws {
        let plan = AudioSessionPlan.capture(for: config)
        try session.setCategory(plan.category, mode: plan.mode, options: plan.options)

        // Speech does not need 48 kHz, but matching common hardware avoids a resampler in
        // the capture path. The analysis path resamples to 16 kHz deliberately.
        try? session.setPreferredSampleRate(48_000)
        // A longer IO buffer means far fewer CPU wakeups over a multi-hour session.
        try? session.setPreferredIOBufferDuration(0.1)

        try session.setActive(true, options: [])

        if plan.preferBuiltInMic { preferBuiltInMicrophone() }
        activePlan = plan
    }

    /// Pin the input to the iPhone's own microphone, and — where the hardware exposes a
    /// choice — ask for the omnidirectional pattern, which is what picks up a room rather
    /// than only the person holding the phone.
    private func preferBuiltInMicrophone() {
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic })
        else { return }

        try? session.setPreferredInput(builtIn)

        if let sources = builtIn.dataSources, !sources.isEmpty {
            let preferred = sources.first { $0.supportedPolarPatterns?.contains(.omnidirectional) == true }
                ?? sources.first { $0.orientation == .bottom }
                ?? sources.first
            if let preferred {
                try? preferred.setPreferredPolarPattern(.omnidirectional)
                try? session.setPreferredDataSource(preferred)
            }
        }
    }

    /// Make sure playback can be heard when the recorder is idle, without disturbing
    /// an active capture session if one is running.
    func activateForPlaybackIfNeeded() throws {
        if session.category != .playAndRecord && session.category != .playback {
            let plan = AudioSessionPlan.playback
            try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
            activePlan = plan
        }
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        activePlan = nil
    }

    // MARK: - Introspection

    /// True when the current route actually offers an input we can record from.
    var hasAvailableInput: Bool {
        !session.currentRoute.inputs.isEmpty || session.isInputAvailable
    }

    var currentInputName: String? {
        session.currentRoute.inputs.first?.portName
    }

    /// True when the input in use is the iPhone's own microphone.
    var isUsingBuiltInMic: Bool {
        session.currentRoute.inputs.first?.portType == .builtInMic
    }

    /// True when another app is playing audio right now — the Spotify case.
    var otherAudioPlaying: Bool {
        session.isOtherAudioPlaying
    }

    var sampleRate: Double { session.sampleRate }

    var ioBufferDuration: TimeInterval { session.ioBufferDuration }

    // MARK: - Notifications

    private func registerForNotifications() {
        notifications.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session
        )
        notifications.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: session
        )
        notifications.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: session
        )
    }

    /// Phone calls, Siri, FaceTime, the camera claiming the mic, another app recording, or
    /// a Control Center deactivation all arrive here.
    @objc private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            Log.audio.notice("Audio session interruption began")
            observer?.sessionInterruptionBegan()
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            Log.audio.notice("Audio session interruption ended, shouldResume=\(options.contains(.shouldResume))")
            observer?.sessionInterruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    /// Headphones in or out, a route override, a configuration change.
    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        Log.audio.notice("Route change reason=\(raw)")
        // A new device may have become the input; re-pin the built-in mic.
        if activePlan?.preferBuiltInMic == true { preferBuiltInMicrophone() }
        observer?.sessionRouteChanged(reason: reason)
    }

    /// The audio server crashed. Every audio object we hold is now invalid.
    @objc private func handleMediaServicesReset(_ note: Notification) {
        Log.audio.error("Media services were reset")
        observer?.sessionMediaServicesWereReset()
    }
}
