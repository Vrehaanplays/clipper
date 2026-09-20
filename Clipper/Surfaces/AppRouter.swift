import Combine
import Foundation

enum AppTab: String, Hashable, CaseIterable {
    case listen
    case timeline
    case memory
    case search
    case settings

    var title: String {
        switch self {
        case .listen: return "Listen"
        case .timeline: return "Timeline"
        case .memory: return "Memory"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .listen: return "waveform"
        case .timeline: return "clock"
        case .memory: return "brain"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

/// A destination inside the Memory tab.
enum MemoryRoute: Hashable {
    case memory(UUID)
    case speaker(UUID)
    case node(UUID)
    case unresolved
}

/// Where the app is, and where something outside it has asked it to go.
///
/// Spotlight results, widget taps, the Live Activity and App Intents all arrive as a
/// `ClipperDeepLink` and end up here. Views observe the pending values and clear them once
/// consumed, so a deep link that arrives before the UI exists is not lost — it is honoured
/// as soon as the relevant screen appears.
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var tab: AppTab = .listen

    /// Consumed and cleared by the screen that handles it.
    @Published var pendingConversation: UUID?
    /// One route rather than four parallel optionals, so the Memory tab has a single
    /// `navigationDestination` and cannot try to push two screens at once.
    @Published var memoryRoute: MemoryRoute?

    /// Pre-filled search text, from Siri or a widget.
    @Published var searchText = ""
    /// Set when a search should run as soon as the screen appears.
    @Published var pendingSearchSubmit = false

    private init() {}

    func handle(_ link: ClipperDeepLink) {
        onMain {
            switch link {
            case .listen:
                self.tab = .listen
            case .today:
                self.tab = .timeline
            case .search(let query):
                self.tab = .search
                if let query, !query.isEmpty {
                    self.searchText = query
                    self.pendingSearchSubmit = true
                }
            case .conversation(let id):
                self.tab = .timeline
                self.pendingConversation = id
            case .memory(let id):
                self.tab = .memory
                self.memoryRoute = .memory(id)
            case .speaker(let id):
                self.tab = .memory
                self.memoryRoute = .speaker(id)
            case .node(let id):
                self.tab = .memory
                self.memoryRoute = .node(id)
            case .unresolved:
                self.tab = .memory
                self.memoryRoute = .unresolved
            }
        }
    }

    /// `clipper://…` from a widget tap, and Core Spotlight identifiers, which are the same
    /// URLs by construction.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let link = ClipperDeepLink(url: url) else { return false }
        handle(link)
        return true
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
