import SwiftUI

/// The rolling buffer: raw audio of everything heard, newest first.
///
/// This is deliberately separate from the Memory tab, and the footer says so. These clips
/// are **temporary** — they hold about 30 minutes and delete themselves as new ones land.
/// The transcripts and memories in the rest of the app are what persist. Conflating the two
/// is the one misunderstanding this screen exists to prevent.
struct ClipsView: View {
    @EnvironmentObject private var library: AudioLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.clips.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing buffered yet", systemImage: "waveform.circle")
                    } description: {
                        Text("Clips appear here as each \(settings.clipMinutes)-minute segment finishes. They are temporary — the oldest is deleted as each new one lands.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Rolling buffer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { library.reload() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(library.clips) { clip in
                    ClipRow(clip: clip)
                }
            } header: {
                Text("Temporary audio")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(library.clips.count) of \(settings.maxClipCount) · \(ClipperFormat.clock(library.bufferedDuration)) · \(library.totalSizeLabel)")
                    Text("This is unprocessed audio of everything the microphone heard, kept for about \(settings.bufferMinutes) minutes. Speech that Clipper recognised is stored separately, with its transcript, under Memory.")
                }
            }

            if let error = library.storageError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.smooth(duration: 0.35), value: library.clips.map(\.url))
    }
}

// MARK: - Row

private struct ClipRow: View {
    let clip: Clip

    @EnvironmentObject private var library: AudioLibrary
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
                library.delete(clip)
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
                library.delete(clip)
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
                Text(ClipperFormat.clock(player.position))
                Spacer()
                Text("-" + ClipperFormat.clock(max(0, player.duration - player.position)))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }
}
