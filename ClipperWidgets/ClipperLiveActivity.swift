import ActivityKit
import SwiftUI
import WidgetKit

/// Clipper's Live Activity: Dynamic Island and Lock Screen.
///
/// The duration is rendered with `Text(_:style: .timer)` from the session's start date, so
/// it counts up **without the app sending any updates**. Only phase changes and the
/// processing count are pushed. That is the difference between a Live Activity that costs
/// nothing and one that burns the system's update budget.
///
/// The controls are the shared `LiveActivityIntent`s, so the Dynamic Island button, the
/// Shortcuts action and the in-app button are one implementation.
struct ClipperLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClipperActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.phase.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: context.state.phase.symbolName)
                            .foregroundStyle(context.state.phase.tint)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 64)
                }

                DynamicIslandExpandedRegion(.center) {
                    if let processing = context.state.processingLabel {
                        Text(processing)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if context.state.lowConfidence {
                        Text("Noisy — results may be weak")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .lineLimit(1)
                    } else {
                        Text("\(ClipperFormat.compactDuration(context.state.speechSeconds)) of speech")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        if context.state.phase == .paused {
                            Button(intent: ResumeClippingIntent()) {
                                Label("Resume", systemImage: "play.fill")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(.accentColor)
                        } else {
                            Button(intent: PauseClippingIntent()) {
                                Label("Pause", systemImage: "pause.fill")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(.secondary)
                        }

                        Button(intent: StopClippingIntent()) {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                    .buttonStyle(.bordered)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                // The compact presentation is a few points wide: a ticking clock is more
                // useful there than a word, and it needs no updates.
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: context.state.phase.symbolName)
                    .foregroundStyle(context.state.phase.tint)
            }
            .widgetURL(ClipperDeepLink.listen.url)
            .keylineTint(context.state.phase.tint)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ClipperActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: context.state.phase.symbolName)
                    .font(.headline)
                    .foregroundStyle(context.state.phase.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(context.state.phase.title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(context.attributes.startedAt, style: .timer)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 10) {
                if context.state.phase == .paused {
                    Button(intent: ResumeClippingIntent()) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button(intent: PauseClippingIntent()) {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
                Button(intent: StopClippingIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
    }

    /// The second line always says something true about what is happening, in priority
    /// order: interrupted beats processing beats a warning beats the speech total.
    private var detail: String {
        switch context.state.phase {
        case .interrupted:
            return "iOS took the microphone — Clipper will resume"
        case .recovering:
            return "Reconnecting to the microphone"
        case .paused:
            return "Nothing is being captured"
        case .permissionDenied:
            return "Microphone access is off"
        case .failed:
            return "Session ended unexpectedly"
        default:
            if let processing = context.state.processingLabel { return processing }
            if context.state.lowConfidence { return "Noisy room — results may be weak" }
            return "\(ClipperFormat.compactDuration(context.state.speechSeconds)) of speech captured"
        }
    }
}
