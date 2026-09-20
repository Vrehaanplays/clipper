import SwiftUI

/// Every switch here changes a real trade-off the user can feel. Nothing is a preference
/// for its own sake, and the footers say what each one costs.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var library: AudioLibrary

    @State private var showingEraseConfirmation = false
    @State private var stats = StoreStatsDTO()

    private let store = ClipperStore.shared
    private let surfaces = SurfaceCoordinator.shared

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                bufferSection
                qualitySection
                processingSection
                retentionSection
                surfaceSection
                storageSection
                privacySection
                diagnosticsSection
            }
            .navigationTitle("Settings")
            .onChange(of: settings.maxClipCount) { _, _ in library.enforceLimit() }
            .onChange(of: settings.sensitivity) { _, _ in recorder.applySensitivityChange() }
            .task { stats = await store.stats() }
            .confirmationDialog("Erase everything Clipper remembers?",
                                isPresented: $showingEraseConfirmation,
                                titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) { eraseEverything() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transcripts, summaries, memories, the brain map, the search index and all retained audio are deleted from this iPhone. This cannot be undone.")
            }
        }
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Picker("Sensitivity", selection: $settings.sensitivity) {
                ForEach(VADSensitivity.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            Text(settings.sensitivity.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Let other apps keep playing", isOn: $settings.letOtherAppsPlay)
            Toggle("Echo cancellation", isOn: $settings.echoCancellation)
        } header: {
            Text("Listening")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clipper always uses the iPhone's built-in microphone, never AirPods or a Bluetooth headset.")
                Text("**Let other apps keep playing** is what lets Spotify or a game carry on while Clipper listens. Turning it off makes Clipper take exclusive control of audio.")
                Text("**Echo cancellation** reduces your own phone's speaker bleeding into the microphone, but iOS ducks or interrupts other apps' audio while it is on — which defeats the point of the setting above. Off by default for that reason.")
                if settings.echoCancellation && settings.letOtherAppsPlay {
                    Text("Both are on. Expect other apps' audio to duck; iOS decides, not Clipper.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Rolling buffer

    private var bufferSection: some View {
        Section {
            Picker("Clip length", selection: $settings.clipMinutes) {
                ForEach(AppSettings.clipMinuteChoices, id: \.self) { minutes in
                    Text(minuteLabel(minutes)).tag(minutes)
                }
            }
            Picker("Buffer", selection: $settings.bufferMinutes) {
                ForEach(AppSettings.bufferMinuteChoices, id: \.self) { minutes in
                    Text(minuteLabel(minutes)).tag(minutes)
                }
            }
        } header: {
            Text("Rolling buffer")
        } footer: {
            Text(bufferFooter)
        }
    }

    private var bufferFooter: String {
        let kept = settings.maxClipCount
        var text = "Raw audio of everything heard: the newest \(kept) clip\(kept == 1 ? "" : "s"), about \(kept * settings.clipMinutes) minutes. The oldest is deleted as each new one finishes. This is separate from the speech Clipper keeps as evidence."
        if recorder.state.isActive {
            text += " Changes take effect at the next clip boundary."
        }
        return text
    }

    private var qualitySection: some View {
        Section {
            Picker("Quality", selection: $settings.quality) {
                ForEach(AudioQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("AAC in an M4A file, tuned for speech. \(settings.quality.footprintLabel).")
        }
    }

    // MARK: - Processing

    private var processingSection: some View {
        Section {
            Toggle("Transcribe speech", isOn: $settings.transcriptionEnabled)
            Toggle("Group voices", isOn: $settings.speakerClusteringEnabled)
            Toggle("Ask who a voice is", isOn: $settings.speakerNamingPrompts)
            Toggle("Write summaries", isOn: $settings.summariesEnabled)
            Toggle("Use the on-device language model", isOn: $settings.preferOnDeviceModel)
        } header: {
            Text("Processing")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("All of it runs on this iPhone. Transcription uses Apple's on-device recogniser and will fail rather than fall back to a server.")
                Text("With the language model off — or unavailable on this device — summaries are built by selecting sentences that were actually said. Plainer, and incapable of inventing anything.")
            }
        }
    }

    // MARK: - Retention

    private var retentionSection: some View {
        Section {
            Toggle("Keep speech audio as evidence", isOn: $settings.keepEvidenceAudio)
            Picker("Keep audio for", selection: $settings.retention) {
                ForEach(EvidenceRetention.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .disabled(!settings.keepEvidenceAudio)
        } header: {
            Text("Retention")
        } footer: {
            Text("Transcripts, summaries and memories are never removed by this policy — only the audio behind them. When a clip expires, its transcript says so rather than showing a dead play button.")
        }
    }

    // MARK: - Surfaces

    private var surfaceSection: some View {
        Section {
            Toggle("Show Clipper Live Activity", isOn: $settings.liveActivityEnabled)
            if settings.liveActivityEnabled && !surfaces.liveActivitiesEnabled {
                Label("Live Activities are turned off for Clipper in iOS Settings.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if surfaces.liveActivityRunning {
                Button("Hide the current Live Activity") {
                    surfaces.hideLiveActivity()
                }
            }

            Toggle("Show memories in the widget", isOn: $settings.widgetContentEnabled)
            if !surfaces.appGroupAvailable {
                Label("The widget cannot read Clipper's status in this build — see Diagnostics.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Include in iPhone search", isOn: $settings.spotlightEnabled)
        } header: {
            Text("Widget and Live Activity")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("These two switches are independent. Turning the Live Activity off ends one that is already on screen; turning widget content off leaves the widget showing status only.")
                Text("Whether a widget is on your Home Screen is up to iOS and you — Clipper cannot add or remove one. The microphone indicator is the operating system's and is always shown while recording.")
                Text("iPhone search receives titles, summaries and keywords only. Raw transcripts are never published to it.")
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Buffered clips", value: "\(library.clips.count) of \(settings.maxClipCount)")
            LabeledContent("Buffer on disk", value: library.totalSizeLabel)
            LabeledContent("Evidence audio",
                           value: ByteCountFormatter.string(fromByteCount: library.evidenceBytes, countStyle: .file))
            LabeledContent("Database",
                           value: ByteCountFormatter.string(fromByteCount: ClipperDatabase.shared.storeByteSize, countStyle: .file))
            if let free = library.availableCapacity {
                LabeledContent("Free space",
                               value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            LabeledContent("Transcript lines", value: "\(stats.transcriptSegments)")
            LabeledContent("Memories", value: "\(stats.memories)")
        } header: {
            Text("Storage")
        } footer: {
            Text("Everything stays in Clipper's private storage on this iPhone. Use Share on a clip or a summary to send anything anywhere else.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("Nothing is uploaded", systemImage: "wifi.slash")
            Label("No account, no analytics", systemImage: "person.crop.circle.badge.xmark")
            Label("Processing happens on this iPhone", systemImage: "iphone")
            Label("iOS always shows the microphone indicator", systemImage: "circle.fill")
        } header: {
            Text("Privacy")
        } footer: {
            Text("Clipper has no network code. Recording is something you start deliberately, and iOS displays its own microphone indicator the whole time — Clipper neither hides nor could hide it.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            Button(role: .destructive) {
                showingEraseConfirmation = true
            } label: {
                Label("Erase everything", systemImage: "trash")
            }
        } footer: {
            Text("Clipper \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")")
        }
    }

    // MARK: - Actions

    private func eraseEverything() {
        if recorder.state.isActive { recorder.stop() }
        // Runs on the main actor: the view's own state and the library's published clip
        // list are both main-queue-only, and the store hop is an `await` rather than a
        // block.
        Task {
            await store.deleteEverything()
            await SpotlightIndexer.shared.removeAll()
            for clip in library.clips { library.delete(clip) }
            library.deleteAllEvidence()
            library.purgeOrphanUtterances(keeping: [])
            stats = await store.stats()
        }
    }

    private func minuteLabel(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
