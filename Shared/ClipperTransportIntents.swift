import AppIntents
import Foundation

/// How a transport intent reaches the recorder.
///
/// The transport intents live in `Shared/` because a Live Activity's `Button(intent:)`
/// needs the intent type compiled into the **widget extension**, while `perform()` runs in
/// the **app** process. One type, two targets — so the intent cannot reference the recorder
/// directly, and goes through this instead.
public protocol ClipperTransportHandling: AnyObject {
    func transportStart()
    func transportStop()
    func transportPause()
    func transportResume()
    var transportIsActive: Bool { get }
    var transportIsPaused: Bool { get }
}

/// Set once, by the app, at launch. Stays `nil` in the widget process, which is correct:
/// `LiveActivityIntent.perform()` is always executed in the app.
public enum ClipperTransport {
    public private(set) static weak var handler: ClipperTransportHandling?

    public static func register(_ handler: ClipperTransportHandling) {
        self.handler = handler
    }
}

public struct StartClippingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Start Listening"
    public static var description = IntentDescription(
        "Starts a Clipper session. Clipper listens through the built-in microphone and keeps listening while you use other apps."
    )
    public static var openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = ClipperTransport.handler else {
            return .result(dialog: "Open Clipper once, then try again.")
        }
        if handler.transportIsPaused {
            handler.transportResume()
            return .result(dialog: "Clipper is listening again.")
        }
        guard !handler.transportIsActive else {
            return .result(dialog: "Clipper is already listening.")
        }
        handler.transportStart()
        // The engine reports the truth a moment later; this says what was asked for.
        return .result(dialog: "Clipper is starting to listen.")
    }
}

public struct StopClippingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Stop Listening"
    public static var description = IntentDescription("Ends the current Clipper session.")
    public static var openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = ClipperTransport.handler, handler.transportIsActive else {
            return .result(dialog: "Clipper was not listening.")
        }
        handler.transportStop()
        return .result(dialog: "Stopped listening.")
    }
}

public struct PauseClippingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Pause Listening"
    public static var description = IntentDescription(
        "Pauses Clipper without ending the session, so resuming is instant."
    )
    public static var openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = ClipperTransport.handler,
              handler.transportIsActive, !handler.transportIsPaused else {
            return .result(dialog: "There is nothing to pause.")
        }
        handler.transportPause()
        return .result(dialog: "Paused.")
    }
}

public struct ResumeClippingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Resume Listening"
    public static var description = IntentDescription("Resumes a paused Clipper session.")
    public static var openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let handler = ClipperTransport.handler, handler.transportIsPaused else {
            return .result(dialog: "Clipper is not paused.")
        }
        handler.transportResume()
        return .result(dialog: "Listening again.")
    }
}
