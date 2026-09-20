import Foundation

/// `clipper://` URLs. Spotlight results, widget taps, the Live Activity and App Intents all
/// route through this one type, so there is exactly one parser and one builder.
public enum ClipperDeepLink: Equatable, Hashable, Sendable {
    case listen
    case today
    case search(String?)
    case conversation(UUID)
    case memory(UUID)
    case speaker(UUID)
    case node(UUID)
    case unresolved

    public static let scheme = "clipper"

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .listen:
            components.host = "listen"
        case .today:
            components.host = "today"
        case .search(let query):
            components.host = "search"
            if let query, !query.isEmpty {
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
        case .conversation(let id):
            components.host = "conversation"
            components.path = "/" + id.uuidString
        case .memory(let id):
            components.host = "memory"
            components.path = "/" + id.uuidString
        case .speaker(let id):
            components.host = "speaker"
            components.path = "/" + id.uuidString
        case .node(let id):
            components.host = "node"
            components.path = "/" + id.uuidString
        case .unresolved:
            components.host = "unresolved"
        }
        // Every branch sets a host, so this is unreachable; the fallback keeps the type
        // non-optional for callers.
        return components.url ?? URL(string: "clipper://listen")!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let identifier = url.pathComponents.first { $0 != "/" }.flatMap(UUID.init(uuidString:))

        switch url.host?.lowercased() {
        case "listen":
            self = .listen
        case "today":
            self = .today
        case "search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
            self = .search(query)
        case "conversation":
            guard let identifier else { return nil }
            self = .conversation(identifier)
        case "memory":
            guard let identifier else { return nil }
            self = .memory(identifier)
        case "speaker":
            guard let identifier else { return nil }
            self = .speaker(identifier)
        case "node":
            guard let identifier else { return nil }
            self = .node(identifier)
        case "unresolved":
            self = .unresolved
        default:
            return nil
        }
    }
}
