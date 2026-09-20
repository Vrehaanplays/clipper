import AppIntents

/// The phrases Siri and Shortcuts offer without the user building anything.
///
/// Every phrase includes `\(.applicationName)`, which App Intents requires, and each
/// intent gets more than one phrasing because the way people actually ask varies. Kept to
/// the ten the platform allows rather than padding it out.
struct ClipperShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .navy }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartClippingIntent(),
            phrases: [
                "Start listening with \(.applicationName)",
                "Start \(.applicationName)",
                "\(.applicationName) listen",
            ],
            shortTitle: "Start Listening",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: StopClippingIntent(),
            phrases: [
                "Stop listening with \(.applicationName)",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Stop Listening",
            systemImageName: "stop.fill"
        )

        AppShortcut(
            intent: PauseClippingIntent(),
            phrases: [
                "Pause \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: ResumeClippingIntent(),
            phrases: [
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: SearchMemoriesIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Ask \(.applicationName)",
            ],
            shortTitle: "Search Memories",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: MemoriesAboutIntent(),
            phrases: [
                "What does \(.applicationName) know about",
                "\(.applicationName) memories about",
            ],
            shortTitle: "Memories About",
            systemImageName: "person.text.rectangle"
        )

        AppShortcut(
            intent: OpenTodayTimelineIntent(),
            phrases: [
                "Open today in \(.applicationName)",
                "\(.applicationName) today",
            ],
            shortTitle: "Today",
            systemImageName: "clock"
        )

        AppShortcut(
            intent: ShowRecentSummaryIntent(),
            phrases: [
                "\(.applicationName) recent summary",
                "What did \(.applicationName) hear",
            ],
            shortTitle: "Recent Summary",
            systemImageName: "doc.text"
        )
    }
}
