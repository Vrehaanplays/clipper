import SwiftUI

/// Three knobs. The defaults are the product; nothing here needs touching.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Clip length", selection: $settings.clipMinutes) {
                        ForEach(AppSettings.clipMinuteChoices, id: \.self) { minutes in
                            Text(label(forMinutes: minutes)).tag(minutes)
                        }
                    }
                    Picker("Buffer", selection: $settings.bufferMinutes) {
                        ForEach(AppSettings.bufferMinuteChoices, id: \.self) { minutes in
                            Text(label(forMinutes: minutes)).tag(minutes)
                        }
                    }
                } header: {
                    Text("Rolling buffer")
                } footer: {
                    Text(bufferFooter)
                }

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

                Section {
                    LabeledContent("Clips kept", value: "\(store.clips.count) of \(settings.maxClipCount)")
                    LabeledContent("On disk", value: store.totalSizeLabel)
                    if let free = store.availableCapacity {
                        LabeledContent("Free space",
                                       value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Recordings stay in Clipper's private storage on this iPhone. Nothing is uploaded. Use Share on a clip to send it anywhere else.")
                }
            }
            .navigationTitle("Settings")
            // Shrinking the buffer must take effect now, not at the next boundary.
            .onChange(of: settings.maxClipCount) { _, _ in store.enforceLimit() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var bufferFooter: String {
        let kept = settings.maxClipCount
        let clipWord = kept == 1 ? "clip" : "clips"
        var text = "Keeps the newest \(kept) \(clipWord) — about \(kept * settings.clipMinutes) minutes. The oldest clip is deleted as each new one finishes."
        if recorder.state.isActive {
            text += " Changes take effect at the next clip boundary."
        }
        return text
    }

    private func label(forMinutes minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
        .environmentObject(AudioRecorder.shared)
        .environmentObject(ClipStore.shared)
}
