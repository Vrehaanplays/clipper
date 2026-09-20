import SwiftUI

/// The honesty label, rendered the same way everywhere it appears.
///
/// This badge is load-bearing rather than decorative: the whole app rests on the user being
/// able to tell a quoted sentence from a paraphrase from a guess, so every derived string
/// in the UI is accompanied by one of these.
struct AssertionBadge: View {
    let assertion: AssertionKind
    var confidence: Double?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: assertion.symbolName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
            if !compact {
                Text(assertion.title)
                    .font(.caption2.weight(.medium))
            }
            if let confidence, !compact {
                Text("· \(Int((confidence * 100).rounded()))%")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityLabel(accessibilityText)
    }

    private var tint: Color {
        switch assertion {
        case .stated: return .green
        case .summarised: return .blue
        case .inferred: return .purple
        case .uncertain: return .orange
        case .contradictory: return .red
        case .unsupported: return .red
        }
    }

    private var accessibilityText: String {
        guard let confidence else { return assertion.title }
        return "\(assertion.title), confidence \(Int((confidence * 100).rounded())) percent"
    }
}

/// A stable colour per speaker cluster, so the same voice looks the same on every screen.
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]

    static func color(for index: Int) -> Color {
        colors[abs(index) % colors.count]
    }
}

struct SpeakerChip: View {
    let label: String
    let colorIndex: Int
    var isUnknown = false
    var confidence: Double?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isUnknown ? Color.secondary : SpeakerPalette.color(for: colorIndex))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isUnknown ? .secondary : .primary)
            if let confidence, confidence < 0.6 {
                Image(systemName: "questionmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Thin bar for a 0...1 score. Used for confidence and importance.
struct ScoreBar: View {
    let value: Double
    var tint: Color = .accentColor
    var width: CGFloat = 48

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().fill(tint.opacity(0.7))
                .frame(width: max(2, width * CGFloat(min(1, max(0, value)))))
        }
        .frame(width: width, height: 4)
        .accessibilityHidden(true)
    }
}

/// Small labelled row used across the detail screens.
struct DetailRow: View {
    let label: String
    let value: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A kind tag with its SF Symbol.
struct KindTag: View {
    let symbolName: String
    let title: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Used while a screen's first fetch is in flight, so a list never flashes an empty state
/// it is about to replace.
struct LoadingPlaceholder: View {
    var label = "Loading"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}
