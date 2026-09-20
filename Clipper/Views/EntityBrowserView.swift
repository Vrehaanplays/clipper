import SwiftUI

/// People, topics, projects and places — the same screen, parameterised by node kind.
///
/// One implementation rather than four near-identical ones: the only thing that differs is
/// which nodes are fetched and the wording, and duplicating the paging and the search for
/// each would be four places to fix a bug.
struct EntityBrowserView: View {
    let kind: NodeKind

    @State private var nodes: [GraphNodeDTO] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var canLoadMore = true

    private let pageSize = 40
    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                if isLoading && nodes.isEmpty {
                    LoadingPlaceholder()
                } else if nodes.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: kind.symbolName)
                    } description: {
                        Text(emptyMessage)
                    }
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(nodes) { node in
                        NavigationLink {
                            BrainMapView(focusNodeID: node.id)
                        } label: {
                            EntityRow(node: node)
                        }
                    }
                    if canLoadMore && query.isEmpty {
                        Button("Load more") { Task { await loadPage() } }
                            .font(.subheadline)
                    }
                }
            } footer: {
                Text(footerText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter \(title.lowercased())")
        .task { await reload() }
        .onChange(of: query) { _, _ in Task { await reload() } }
    }

    private var title: String {
        switch kind {
        case .person: return "People"
        case .topic: return "Topics"
        case .project: return "Projects"
        case .place: return "Places"
        default: return kind.title
        }
    }

    private var emptyTitle: String {
        query.isEmpty ? "No \(title.lowercased()) yet" : "No matches"
    }

    private var emptyMessage: String {
        switch kind {
        case .person:
            return "Names Clipper hears in conversation appear here. This is different from Voices, which groups audio by who was speaking."
        case .topic:
            return "Recurring subjects appear here once Clipper has heard them more than once."
        case .project:
            return "Organisations and named projects appear here as they are mentioned."
        case .place:
            return "Places mentioned in conversation appear here."
        default:
            return "Nothing here yet."
        }
    }

    private var footerText: String {
        switch kind {
        case .person:
            return "Detected with Apple's on-device name recogniser, from transcripts that already contain recognition errors — so expect some noise."
        default:
            return "Ranked by how often each has been mentioned."
        }
    }

    private func reload() async {
        nodes = []
        canLoadMore = true
        isLoading = true
        await loadPage()
    }

    private func loadPage() async {
        if !query.isEmpty {
            let matches = await store.nodes(matching: query, limit: 40)
            nodes = matches.filter { $0.kind == kind }
            canLoadMore = false
            isLoading = false
            return
        }
        let page = await store.nodes(kind: kind, limit: pageSize, offset: nodes.count)
        nodes.append(contentsOf: page)
        canLoadMore = page.count == pageSize
        isLoading = false
    }
}

private struct EntityRow: View {
    let node: GraphNodeDTO

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbolName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.subheadline)
                Text("\(node.mentionCount) mention\(node.mentionCount == 1 ? "" : "s") · last \(node.lastMentionedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if node.summaryID != nil {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Has a summary")
            }
            ScoreBar(value: node.importance, width: 26)
        }
    }
}
