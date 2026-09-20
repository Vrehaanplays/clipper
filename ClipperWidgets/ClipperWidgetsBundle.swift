import SwiftUI
import WidgetKit

/// The extension's entry point. Two widgets: the Home Screen / Lock Screen status widget,
/// and the Live Activity that renders in the Dynamic Island.
///
/// The extension does **no work**: it has no database, no audio, no model inference. It
/// renders a snapshot the app prepared and a Live Activity content state the app pushed.
/// That is a requirement rather than a simplification — widget extensions get a small
/// memory budget and are killed for exceeding it.
@main
struct ClipperWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ClipperStatusWidget()
        ClipperLiveActivityWidget()
    }
}

// MARK: - Shared presentation

extension ClipperPhase {
    /// Widget-side colours. Kept here rather than in `Shared/` so the shared layer stays
    /// free of SwiftUI and can be used from tests and from non-UI code.
    var tint: Color {
        switch self {
        case .speech: return .red
        case .listening: return .pink
        case .starting, .recovering: return .orange
        case .interrupted: return .yellow
        case .paused: return .secondary
        case .permissionDenied, .failed: return .orange
        case .inactive: return .secondary
        }
    }
}
