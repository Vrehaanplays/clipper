import AVFoundation
import Foundation

/// Everything the recorder needs to know about the system taking the mic away.
protocol AudioSessionObserver: AnyObject {
    func sessionInterruptionBegan()
    func sessionInterruptionEnded(shouldResume: Bool)
    func sessionRouteChanged(reason: AVAudioSession.RouteChangeReason)
    func sessionMediaServicesWereReset()
}

/// Sole owner of `AVAudioSession`. Nothing else in the app configures it.
///
/// The category is `.playAndRecord` for the whole capture lifetime so that playing a
/// clip back never requires a category switch — a switch mid-capture would tear down
/// the engine and cost a segment.
final class AudioSessionManager: NSObject {
    static let shared = AudioSessionManager()

    weak var observer: AudioSessionObserver?

    private let session = AVAudioSession.sharedInstance()
    private let notifications = NotificationCenter.default

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
    func activateForCapture() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        // Speech does not need 48 kHz, but matching common hardware avoids a resampler.
        try? session.setPreferredSampleRate(48_000)
        // A longer IO buffer means far fewer CPU wakeups over a multi-hour session.
        try? session.setPreferredIOBufferDuration(0.1)
        try session.setActive(true, options: [])
    }

    /// Make sure playback can be heard when the recorder is idle, without disturbing
    /// an active capture session if one is running.
    func activateForPlaybackIfNeeded() throws {
        if session.category != .playAndRecord && session.category != .playback {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// True when the current route actually offers an input we can record from.
    var hasAvailableInput: Bool {
        !session.currentRoute.inputs.isEmpty || session.isInputAvailable
    }

    var currentInputName: String? {
        session.currentRoute.inputs.first?.portName
    }

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

    /// Phone calls, Siri, FaceTime, another app claiming the mic, or a Control Center
    /// deactivation all arrive here.
    @objc private func handleInterruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            observer?.sessionInterruptionBegan()
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            observer?.sessionInterruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            break
        }
    }

    /// Headphones in or out, a Bluetooth mic connecting, a USB interface arriving.
    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        observer?.sessionRouteChanged(reason: reason)
    }

    /// The audio server crashed. Every audio object we hold is now invalid.
    @objc private func handleMediaServicesReset(_ note: Notification) {
        observer?.sessionMediaServicesWereReset()
    }
}
