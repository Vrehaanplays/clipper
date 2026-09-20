import SwiftUI
import WidgetKit

/// One timeline entry. `snapshot == nil` means the shared container was not readable —
/// almost always because the app group is not provisioned on a free-signed build.
struct ClipperStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: ClipperSnapshot?
    /// True when the container itself is unavailable, as opposed to simply empty.
    let containerUnavailable: Bool
}

struct ClipperStatusProvider: TimelineProvider {
    private let group = AppGroupStore.shared

    func placeholder(in context: Context) -> ClipperStatusEntry {
        ClipperStatusEntry(date: Date(), snapshot: .placeholder, containerUnavailable: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClipperStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClipperStatusEntry>) -> Void) {
        let entry = currentEntry()
        // The app reloads the timeline on every phase change, so this interval only covers
        // the case where the app is not running at all. Fifteen minutes is frequent enough
        // to clear a stale "Listening" badge and infrequent enough to cost nothing.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> ClipperStatusEntry {
        guard group.isAvailable else {
            return ClipperStatusEntry(date: Date(), snapshot: nil, containerUnavailable: true)
        }
        return ClipperStatusEntry(date: Date(),
                                  snapshot: group.read() ?? ClipperSnapshot(),
                                  containerUnavailable: false)
    }
}

struct ClipperStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClipperStatusWidget", provider: ClipperStatusProvider()) { entry in
            ClipperStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Clipper")
        .description("Whether Clipper is listening, and your most recent memory.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct ClipperStatusView: View {
    let entry: ClipperStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(link.url)
    }

    @ViewBuilder
    private var content: some View {
        if entry.containerUnavailable {
            unavailable
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
    }

    // MARK: - Data

    private var snapshot: ClipperSnapshot { entry.snapshot ?? ClipperSnapshot() }

    /// A snapshot that still says "listening" long after the app was killed is a lie about
    /// whether the microphone is live, so staleness is rendered as its own state.
    private var phase: ClipperPhase {
        snapshot.isStale ? .inactive : snapshot.phase
    }

    private var statusText: String {
        snapshot.isStale ? "Status unknown" : phase.title
    }

    private var link: ClipperDeepLink {
        phase.isSessionActive ? .listen : .today
    }

    // MARK: - Families

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            if phase.isSessionActive, let started = snapshot.sessionStartedAt {
                Text(started, style: .timer)
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("\(snapshot.speechLabel) of speech")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let memory = snapshot.recentMemory {
                Text(memory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text(snapshot.memoryCount == 0
                     ? "Nothing stored yet"
                     : "\(snapshot.memoryCount) memories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let processing = processingLabel {
                Text(processing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if phase.isSessionActive, let started = snapshot.sessionStartedAt {
                    Text(started, style: .timer)
                        .font(.system(.title2, design: .rounded, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("\(snapshot.speechLabel) of speech")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(snapshot.memoryCount) memories")
                        .font(.system(.title3, design: .rounded, weight: .medium))
                }
                if let processing = processingLabel {
                    Text(processing).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Link(destination: ClipperDeepLink.search(nil).url) {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.caption2.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.recentSummary == nil ? "Latest memory" : "Latest summary")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.recentSummary ?? snapshot.recentMemory ?? "Nothing yet")
                    .font(.caption)
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: phase.symbolName)
                Text(statusText).font(.headline)
            }
            if phase.isSessionActive, let started = snapshot.sessionStartedAt {
                Text(started, style: .timer).monospacedDigit()
            } else if let memory = snapshot.recentMemory {
                Text(memory).lineLimit(1)
            } else {
                Text("\(snapshot.memoryCount) memories")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: phase.symbolName)
                    .font(.system(size: 15, weight: .medium))
                if phase.isSessionActive {
                    Text(snapshot.speechLabel)
                        .font(.system(size: 9, design: .rounded))
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: phase.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(phase.tint)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if snapshot.lowConfidence && phase.isCapturingAudio {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
    }

    private var processingLabel: String? {
        guard snapshot.isProcessing, snapshot.pendingJobs > 0 else { return nil }
        return snapshot.pendingJobs == 1
            ? "1 clip processing"
            : "\(snapshot.pendingJobs) clips processing"
    }

    /// Honest degradation. A free Apple ID cannot provision an app group, so a sideloaded
    /// build often cannot read the app's status at all. Saying so beats an empty widget
    /// that looks broken.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Open Clipper")
                .font(.caption.weight(.semibold))
            Text("Live status needs the app group, which this build was not signed with.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
