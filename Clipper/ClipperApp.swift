import SwiftUI

@main
struct ClipperApp: App {
    // The engine, store and player are long-lived singletons created before any view
    // exists. SwiftUI observes them; it never owns them. That is what lets recording
    // survive the UI being suspended, backgrounded or torn down.
    @StateObject private var recorder = AudioRecorder.shared
    @StateObject private var store = ClipStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var player = AudioPlayer.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Crash recovery runs before the first frame: create the directory, drop any
        // `.part` debris, rebuild metadata from disk and enforce the buffer limit.
        ClipStore.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(player)
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the foreground, trust the disk rather than memory.
                    if phase == .active { store.reload() }
                }
        }
    }
}
