import Foundation

/// Wires the shared transport intents to the real engine.
///
/// The intents in `Shared/ClipperTransportIntents.swift` cannot see `AudioRecorder` — they
/// are compiled into the widget extension too. This is the app-side half: the recorder
/// registers itself at launch, and from then on a Dynamic Island button, a Shortcuts
/// action and a Siri phrase all drive the same code path as the on-screen button.
extension AudioRecorder: ClipperTransportHandling {
    func transportStart() { start() }
    func transportStop() { stop() }
    func transportPause() { pause() }
    func transportResume() { resume() }
    var transportIsActive: Bool { state.isActive }
    var transportIsPaused: Bool { state == .paused }
}
