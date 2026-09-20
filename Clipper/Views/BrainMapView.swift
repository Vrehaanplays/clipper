import SwiftUI

/// The brain map: one node and its immediate neighbourhood.
///
/// ## Why it is never the whole graph
/// A graph view that renders everything stops working at a few hundred nodes and is
/// meaningless long before that. So this screen always shows a **focused subgraph**: one
/// node, its strongest neighbours, and the edges between them. Expanding walks outward one
/// hop at a time, and re-focusing on a neighbour is how you traverse.
///
/// Every edge is listed underneath the diagram with the transcript lines that created it,
/// because an unexplainable relationship in a memory system is worse than no relationship.
struct BrainMapView: View {
    let focusNodeID: UUID?

    @State private var focus: UUID?
    @State private var subgraph: SubgraphDTO?
    @State private var rootNodes: [GraphNodeDTO] = []
    @State private var kindFilter: NodeKind?
    @State private var neighbourLimit = 12
    @State private var minimumWeight: Double = 1
    @State private var zoom: CGFloat = 1
    @State private var isLoading = true
    @State private var summary: SummaryDTO?

    private let store = ClipperStore.shared

    var body: some View {
        Group {
            if let subgraph {
                focused(subgraph)
            } else {
                picker
            }
        }
        .navigationTitle(subgraph?.focus.name ?? "Brain map")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            focus = focusNodeID
            await load()
        }
    }

    // MARK: - Picker (no focus yet)

    private var picker: some View {
        List {
            Section {
                Picker("Type", selection: $kindFilter) {
                    Text("Everything").tag(NodeKind?.none)
                    ForEach(NodeKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
            } footer: {
                Text("Pick something to focus on. The map opens around it, one hop at a time.")
            }

            Section {
                if isLoading {
                    LoadingPlaceholder()
                } else if rootNodes.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing mapped yet", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("People, topics and projects appear here as Clipper hears them mentioned.")
                    }
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(rootNodes) { node in
                        Button {
                            focus = node.id
                            Task { await load() }
                        } label: {
                            NodeRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: kindFilter) { _, _ in Task { await load() } }
    }

    // MARK: - Focused subgraph

    private func focused(_ graph: SubgraphDTO) -> some View {
        List {
            Section {
                SubgraphCanvas(graph: graph, zoom: zoom) { tapped in
                    focus = tapped
                    Task { await load() }
                }
                .frame(height: 300)
                .listRowInsets(EdgeInsets())

                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 0.6...1.8)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text(graph.focus.kind.title)
            } footer: {
                Text("\(graph.neighbours.count) neighbour\(graph.neighbours.count == 1 ? "" : "s") shown\(graph.hasMore ? ", more available" : "") · mentioned \(graph.focus.mentionCount) times")
            }

            if let summary {
                Section("What Clipper knows about this") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.text).font(.footnote)
                        AssertionBadge(assertion: summary.assertion, confidence: summary.confidence)
                    }
                }
            }

            Section {
                if graph.hasMore {
                    Button("Show more neighbours") {
                        neighbourLimit += 12
                        Task { await load() }
                    }
                    .font(.subheadline)
                }
                HStack {
                    Text("Minimum strength")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f", minimumWeight))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $minimumWeight, in: 1...10, step: 1) { editing in
                    if !editing { Task { await load() } }
                }
            } header: {
                Text("Filters")
            } footer: {
                Text("Strength is how often two things were mentioned together. Raising it prunes the weak, incidental links.")
            }

            Section {
                ForEach(graph.edges) { edge in
                    NavigationLink {
                        EdgeEvidenceView(edge: edge, graph: graph)
                    } label: {
                        EdgeRow(edge: edge, graph: graph)
                    }
                    .disabled(!edge.isExplainable)
                }
            } header: {
                Text("Relationships")
            } footer: {
                Text("Tap a relationship to read the transcript lines that created it.")
            }

            Section {
                NavigationLink {
                    NodeMemoriesView(node: graph.focus)
                } label: {
                    Label("Memories about \(graph.focus.name)", systemImage: "brain")
                }
                Button {
                    focus = nil
                    subgraph = nil
                    Task { await load() }
                } label: {
                    Label("Back to the whole map", systemImage: "list.bullet")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        guard let focus else {
            subgraph = nil
            summary = nil
            rootNodes = await store.nodes(kind: kindFilter, limit: 60)
            return
        }

        subgraph = await store.subgraph(around: focus,
                                        maxNeighbours: neighbourLimit,
                                        minWeight: minimumWeight)
        if let summaryID = subgraph?.focus.summaryID {
            summary = await store.summary(id: summaryID)
        } else {
            // `??` is an autoclosure, so the fallback has to be spelled out to stay awaitable.
            if let topic = await store.summary(scope: .topic, key: focus.uuidString) {
                summary = topic
            } else {
                summary = await store.summary(scope: .project, key: focus.uuidString)
            }
        }
    }
}

// MARK: - Canvas

/// Radial layout: focus in the middle, neighbours on a ring, edges drawn behind.
///
/// Deliberately not a force-directed simulation — a layout that moves while you look at it
/// is harder to read, and a deterministic ring means the same node is always in the same
/// place when you come back to it.
private struct SubgraphCanvas: View {
    let graph: SubgraphDTO
    let zoom: CGFloat
    let onTap: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.68 * zoom
            let positions = layout(centre: centre, radius: radius)

            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = positions[edge.sourceNodeID],
                              let to = positions[edge.targetNodeID] else { continue }
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        // Thicker means more co-occurrence: the strength is visible without
                        // reading a number.
                        let width = min(4, 0.8 + edge.weight * 0.25)
                        context.stroke(path,
                                       with: .color(.secondary.opacity(0.35)),
                                       lineWidth: width)
                    }
                }

                ForEach(graph.neighbours) { node in
                    if let point = positions[node.id] {
                        NodeBubble(node: node, isFocus: false)
                            .position(point)
                            .onTapGesture { onTap(node.id) }
                    }
                }

                NodeBubble(node: graph.focus, isFocus: true)
                    .position(centre)
            }
        }
        .padding(8)
        .accessibilityLabel("Map of \(graph.focus.name) and \(graph.neighbours.count) connected items")
    }

    private func layout(centre: CGPoint, radius: CGFloat) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [graph.focus.id: centre]
        let count = max(1, graph.neighbours.count)
        for (index, node) in graph.neighbours.enumerated() {
            // Start at the top and go clockwise.
            let angle = (Double(index) / Double(count)) * 2 * .pi - .pi / 2
            positions[node.id] = CGPoint(x: centre.x + radius * cos(angle),
                                         y: centre.y + radius * sin(angle))
        }
        return positions
    }
}

private struct NodeBubble: View {
    let node: GraphNodeDTO
    let isFocus: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: node.kind.symbolName)
                .font(.system(size: isFocus ? 15 : 11, weight: .semibold))
            Text(node.name)
                .font(.system(size: isFocus ? 11 : 9, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: isFocus ? 92 : 68)
        }
        .padding(.horizontal, isFocus ? 12 : 8)
        .padding(.vertical, isFocus ? 9 : 6)
        .background(isFocus ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(isFocus ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1))
    }
}

// MARK: - Rows

private struct NodeRow: View {
    let node: GraphNodeDTO

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.kind.symbolName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.subheadline)
                Text("\(node.kind.title) · \(node.mentionCount) mention\(node.mentionCount == 1 ? "" : "s") · last \(node.lastMentionedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            ScoreBar(value: node.importance, width: 28)
        }
    }
}

private struct EdgeRow: View {
    let edge: GraphEdgeDTO
    let graph: SubgraphDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(description)
                .font(.footnote)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("strength \(String(format: "%.0f", edge.weight))")
                Text("·")
                Text("\(edge.evidenceIDs.count) source\(edge.evidenceIDs.count == 1 ? "" : "s")")
                if !edge.isExplainable {
                    Text("· no evidence recorded").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var description: String {
        let from = name(for: edge.sourceNodeID)
        let to = name(for: edge.targetNodeID)
        return "\(from) \(edge.kind.label) \(to)"
    }

    private func name(for id: UUID) -> String {
        if id == graph.focus.id { return graph.focus.name }
        return graph.neighbours.first { $0.id == id }?.name ?? "something"
    }
}

// MARK: - Edge evidence

/// Why Clipper thinks two things are related, in the speakers' own words.
struct EdgeEvidenceView: View {
    let edge: GraphEdgeDTO
    let graph: SubgraphDTO

    @State private var lines: [TranscriptLineDTO] = []
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                DetailRow(label: "Relationship", value: edge.kind.label, systemImage: "arrow.left.and.right")
                DetailRow(label: "Strength", value: String(format: "%.0f", edge.weight), systemImage: "chart.bar")
                DetailRow(label: "Confidence",
                          value: "\(Int((edge.confidence * 100).rounded()))%",
                          systemImage: "gauge.medium")
            } footer: {
                Text("Strength accumulates every time the two were mentioned together. It is a count, not a judgement.")
            }

            Section("Evidence") {
                if isLoading {
                    LoadingPlaceholder()
                } else if lines.isEmpty {
                    Text("The transcript lines behind this relationship are no longer available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lines) { line in
                        NavigationLink {
                            EvidenceDetailView(line: line, conversation: nil, summary: nil)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text).font(.footnote).lineLimit(3)
                                Text(line.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Why")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            lines = await store.transcriptLines(ids: edge.evidenceIDs)
            isLoading = false
        }
    }
}

// MARK: - Node memories

struct NodeMemoriesView: View {
    let node: GraphNodeDTO

    @State private var memories: [MemoryDTO] = []
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                if isLoading {
                    LoadingPlaceholder()
                } else if memories.isEmpty {
                    Text("Nothing durable is attached to this yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(memories) { memory in
                        NavigationLink {
                            MemoryDetailView(memoryID: memory.id)
                        } label: {
                            MemoryRow(memory: memory)
                        }
                    }
                }
            } header: {
                Text("\(memories.count) memor\(memories.count == 1 ? "y" : "ies")")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            memories = await store.memories(nodeID: node.id, limit: 60)
            isLoading = false
        }
    }
}
