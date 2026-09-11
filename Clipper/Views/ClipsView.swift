import SwiftUI

/// The rolling buffer, newest first. Play, scrub, share, delete — nothing more.
struct ClipsView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.clips.isEmpty {
                    ContentUnavailableView {
                        Label("No clips yet", systemImage: "waveform")
                    } description: {
                        Text("Start recording and clips will appear here, newest first.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Clips")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { store.reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.clips) { clip in
                    ClipRow(clip: clip)
                }
            } footer: {
                Text("\(store.clips.count) of \(settings.maxClipCount) · \(Clip.clockString(store.bufferedDuration)) · \(store.totalSizeLabel)")
            }
        }
        .listStyle(.insetGrouped)
        .animation(.smooth(duration: 0.35), value: store.clips.map(\.url))
    }

}

// MARK: - Row

private struct ClipRow: View {
    let clip: Clip

    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var player: AudioPlayer

    private var isLoaded: Bool { player.isLoaded(clip) }
    private var isPlaying: Bool { player.isPlaying(clip) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    player.toggle(clip)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentTransition(.symbolEffect(.replace))
                }
                .subtleGlass()
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.timeLabel)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                    Text("\(clip.dayLabel) · \(clip.sizeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(clip.durationLabel)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if isLoaded {
                scrubber
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                player.forgetIfPlaying(clip)
                store.delete(clip)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            ShareLink(item: clip.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            // The only way audio leaves the app: a share sheet the user drives.
            ShareLink(item: clip.url) {
                Label("Share clip", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                player.forgetIfPlaying(clip)
                store.delete(clip)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .animation(.smooth(duration: 0.3), value: isLoaded)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.position },
                    set: { player.position = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    if !editing { player.commitScrub() }
                }
            )
            .tint(.accentColor)

            HStack {
                Text(Clip.clockString(player.position))
                Spacer()
                Text("-" + Clip.clockString(max(0, player.duration - player.position)))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    ClipsView()
        .environmentObject(ClipStore.shared)
        .environmentObject(AppSettings.shared)
        .environmentObject(AudioPlayer.shared)
}
