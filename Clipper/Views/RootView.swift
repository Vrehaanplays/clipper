import CoreSpotlight
import SwiftUI

/// The five tabs, and the one place external navigation lands.
///
/// Spotlight taps, widget taps, the Live Activity and App Intents all arrive as a
/// `ClipperDeepLink`, are handed to `AppRouter`, and the relevant screen consumes the
/// pending value when it appears. Nothing navigates by reaching into another view's state.
struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var pipeline: PipelineStatus

    var body: some View {
        TabView(selection: $router.tab) {
            ListenView()
                .tabItem { Label(AppTab.listen.title, systemImage: AppTab.listen.symbolName) }
                .tag(AppTab.listen)
                // Work still in flight, so the user can tell "nothing was heard" from
                // "not finished thinking about it yet".
                .badge(pipeline.pending)

            MemoryTimelineView()
                .tabItem { Label(AppTab.timeline.title, systemImage: AppTab.timeline.symbolName) }
                .tag(AppTab.timeline)

            MemoryHubView()
                .tabItem { Label(AppTab.memory.title, systemImage: AppTab.memory.symbolName) }
                .tag(AppTab.memory)

            SearchView()
                .tabItem { Label(AppTab.search.title, systemImage: AppTab.search.symbolName) }
                .tag(AppTab.search)

            SettingsView()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbolName) }
                .tag(AppTab.settings)
        }
        .onOpenURL { url in
            router.handle(url: url)
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // Core Spotlight identifiers *are* the deep links, by construction.
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let url = URL(string: identifier) else { return }
            router.handle(url: url)
        }
    }
}
