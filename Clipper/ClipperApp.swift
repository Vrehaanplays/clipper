import SwiftUI

@main
struct ClipperApp: App {
    // The engine, the library, the pipeline and the router are long-lived singletons
    // created before any view exists. SwiftUI observes them; it never owns them. That is
    // what lets a session survive the UI being suspended, backgrounded or torn down.
    @StateObject private var recorder = AudioRecorder.shared
    @StateObject private var library = AudioLibrary.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var player = AudioPlayer.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var pipeline = PipelineCoordinator.shared.status

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Order matters here.
        //
        // 1. Files first: create the directories and drop crash debris, because everything
        //    below may want to read or write them.
        AudioLibrary.shared.bootstrap()

        // 2. Wire the shared transport intents to the real engine, so a Dynamic Island
        //    button or a Siri phrase works even before the first view appears.
        ClipperTransport.register(AudioRecorder.shared)

        // 3. Give the recorder its consumer. The recorder knows nothing about databases or
        //    models; it just hands finished work to this.
        AudioRecorder.shared.pipeline = PipelineCoordinator.shared

        // 4. Crash recovery and the first drain: requeue stranded jobs, close sessions and
        //    conversations a kill left open, purge orphan audio.
        PipelineCoordinator.shared.bootstrap()

        // 5. Surfaces last: it reads the recorder and the pipeline, both of which now exist.
        SurfaceCoordinator.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(recorder)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(player)
                .environmentObject(router)
                .environmentObject(pipeline)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    // Coming back to the foreground, trust the disk rather than memory, and
                    // pick up anything queued while we were suspended.
                    library.reload()
                    PipelineCoordinator.shared.resumeIfNeeded()
                    SurfaceCoordinator.shared.refresh()
                }
        }
    }
}
