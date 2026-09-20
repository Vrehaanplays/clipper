import SwiftUI

/// The status line: a dot that breathes only while audio is genuinely being captured,
/// plus the engine's own description of what it is doing.
///
/// The dot's animation is driven by `isCapturingAudio`, not by the button having been
/// tapped, so a paused or interrupted session visibly stops moving.
struct RecordingIndicator: View {
    let state: RecorderState

    var body: some View {
        HStack(spacing: 9) {
            StatusDot(state: state)
            Text(state.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.isCapturingAudio ? .primary : .secondary)
                .contentTransition(.opacity)
        }
        .animation(.smooth(duration: 0.35), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.title)
        .accessibilityValue(state.detail ?? "")
    }
}

private struct StatusDot: View {
    let state: RecorderState
    @State private var pulse = false

    private var isLive: Bool { state.isCapturingAudio }

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 9, height: 9)
            .overlay {
                if isLive {
                    Circle()
                        .stroke(state.tint.opacity(0.5), lineWidth: 3)
                        .scaleEffect(pulse ? 3.0 : 1.0)
                        .opacity(pulse ? 0 : 0.9)
                }
            }
            .onChange(of: isLive, initial: true) { _, live in
                pulse = false
                guard live else { return }
                // Speech beats faster than idle listening — the state is legible at a
                // glance without reading the label.
                let period = state.isSpeechDetected ? 1.1 : 1.9
                withAnimation(.easeOut(duration: period).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
            .accessibilityHidden(true)
    }
}
