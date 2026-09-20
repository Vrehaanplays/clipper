import SwiftUI

/// The Memory tab: recent important memories at the top, and a way into every other view
/// of the same data below.
///
/// Only the first section loads data. Everything else is a link, so opening this tab costs
/// one bounded query however much history exists.
struct MemoryHubView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var important: [MemoryDTO] = []
    @State private var stats = StoreStatsDTO()
    @State private var openContradictions = 0
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        NavigationStack {
            List {
                importantSection
                browseSection
                peopleSection
                maintenanceSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Memory")
            .navigationDestination(item: $router.memoryRoute) { route in
                switch route {
                case .memory(let id): MemoryDetailView(memoryID: id)
                case .speaker(let id): SpeakerDetailView(speakerID: id)
                case .node(let id): BrainMapView(focusNodeID: id)
                case .unresolved: UnresolvedView()
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: pipeline.revision) { _, _ in Task { await load() } }
        }
    }

    // MARK: - Sections

    private var importantSection: some View {
        Section {
            if isLoading {
                LoadingPlaceholder()
            } else if important.isEmpty {
                ContentUnavailableView {
                    Label("No memories yet", systemImage: "brain")
                } description: {
                    Text("Start listening. Once Clipper recognises speech it builds transcripts, then summaries, then durable memories.")
                }
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(important) { memory in
                    NavigationLink {
                        MemoryDetailView(memoryID: memory.id)
                    } label: {
                        MemoryRow(memory: memory)
                    }
                }
            }
        } header: {
            Text("Recent and important")
        } footer: {
            if !important.isEmpty {
                Text("Ranked by evidence, repetition and recency. The badge on each says how strongly it is claimed.")
            }
        }
    }

    private var browseSection: some View {
        Section("Browse") {
            NavigationLink {
                MemoryListView(kinds: [], title: "All memories")
            } label: {
                hubRow(icon: "brain", title: "All memories", count: stats.memories)
            }
            NavigationLink {
                UnresolvedView()
            } label: {
                hubRow(icon: "questionmark.folder", title: "Unresolved items", count: nil)
            }
            NavigationLink {
                SummaryListView()
            } label: {
                hubRow(icon: "doc.text", title: "Summaries", count: stats.summaries)
            }
            NavigationLink {
                EntityBrowserView(kind: .topic)
            } label: {
                hubRow(icon: "tag", title: "Topics", count: nil)
            }
            NavigationLink {
                EntityBrowserView(kind: .project)
            } label: {
                hubRow(icon: "folder", title: "Projects", count: nil)
            }
            NavigationLink {
                EntityBrowserView(kind: .place)
            } label: {
                hubRow(icon: "mappin", title: "Places", count: nil)
            }
            NavigationLink {
                BrainMapView(focusNodeID: nil)
            } label: {
                hubRow(icon: "point.3.filled.connected.trianglepath.dotted",
                       title: "Brain map",
                       count: stats.nodes)
            }
        }
    }

    private var peopleSection: some View {
        Section("People") {
            NavigationLink {
                EntityBrowserView(kind: .person)
            } label: {
                hubRow(icon: "person.2", title: "People mentioned", count: nil)
            }
            NavigationLink {
                SpeakerManagerView()
            } label: {
                hubRow(icon: "person.wave.2",
                       title: "Voices",
                       count: stats.speakers,
                       detail: stats.namedSpeakers > 0 ? "\(stats.namedSpeakers) named" : "none named")
            }
        }
    }

    private var maintenanceSection: some View {
        Section {
            NavigationLink {
                ContradictionsView()
            } label: {
                HStack {
                    hubRow(icon: "exclamationmark.2", title: "Contradictions", count: nil)
                    if openContradictions > 0 {
                        Text("\(openContradictions)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                    }
                }
            }
        } footer: {
            Text("When two things you said cannot both be true, Clipper keeps both and shows them here rather than picking one.")
        }
    }

    private func hubRow(icon: String, title: String, count: Int?, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 6)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
            if let count {
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        important = await store.importantMemories(limit: 8)
        stats = await store.stats()
        openContradictions = stats.openContradictions
        isLoading = false
    }
}

// MARK: - Memory list

/// A paginated list of memories, optionally filtered by kind. Used for "all memories" and
/// for every kind-specific view, so there is one implementation of paging.
struct MemoryListView: View {
    let kinds: [MemoryKind]
    let title: String

    @State private var memories: [MemoryDTO] = []
    @State private var isLoading = true
    @State private var canLoadMore = true
    @State private var includeArchived = false
    @State private var selectedKind: MemoryKind?

    private let pageSize = 40
    private let store = ClipperStore.shared

    var body: some View {
        List {
            if !kinds.isEmpty || selectedKind != nil || !memories.isEmpty {
                Section {
                    Picker("Kind", selection: $selectedKind) {
                        Text("All kinds").tag(MemoryKind?.none)
                        ForEach(MemoryKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                    Toggle("Include archived", isOn: $includeArchived)
                }
            }

            Section {
                if isLoading && memories.isEmpty {
                    LoadingPlaceholder()
                } else if memories.isEmpty {
                    Text("Nothing here yet.")
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
                    if canLoadMore {
                        Button("Load more") { Task { await loadPage() } }
                            .font(.subheadline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onChange(of: selectedKind) { _, _ in Task { await reload() } }
        .onChange(of: includeArchived) { _, _ in Task { await reload() } }
    }

    private var activeKinds: [MemoryKind] {
        if let selectedKind { return [selectedKind] }
        return kinds
    }

    private func reload() async {
        memories = []
        canLoadMore = true
        isLoading = true
        await loadPage()
    }

    private func loadPage() async {
        let page = await store.memories(kinds: activeKinds,
                                        includeArchived: includeArchived,
                                        limit: pageSize,
                                        offset: memories.count)
        memories.append(contentsOf: page)
        canLoadMore = page.count == pageSize
        isLoading = false
    }
}

// MARK: - Summaries

struct SummaryListView: View {
    @State private var summaries: [SummaryDTO] = []
    @State private var scope: SummaryScope?
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                Picker("Scope", selection: $scope) {
                    Text("Every level").tag(SummaryScope?.none)
                    ForEach(SummaryScope.allCases, id: \.self) { value in
                        Text(value.title).tag(Optional(value))
                    }
                }
            } footer: {
                Text("Summaries build on each other: conversation, then day, then week, then topic. Each one is generated from the level below it, never from the raw transcript again.")
            }

            Section {
                if isLoading {
                    LoadingPlaceholder()
                } else if summaries.isEmpty {
                    Text("No summaries yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                KindTag(symbolName: "doc.text", title: summary.scope.title, tint: .blue)
                                Spacer()
                                Text(summary.periodStart.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(summary.title)
                                .font(.subheadline.weight(.medium))
                            Text(summary.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                            HStack(spacing: 8) {
                                AssertionBadge(assertion: summary.assertion,
                                               confidence: summary.confidence,
                                               compact: true)
                                Text(summary.generator == "foundationModels" ? "model" : "extractive")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if summary.revision > 1 {
                                    Text("· rev \(summary.revision)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Summaries")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: scope) { _, _ in Task { await load() } }
    }

    private func load() async {
        isLoading = true
        summaries = await store.summaries(scope: scope, limit: 60)
        isLoading = false
    }
}

// MARK: - Unresolved

/// Questions, tasks and reminders Clipper heard and nothing has closed.
struct UnresolvedView: View {
    @State private var memories: [MemoryDTO] = []
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                if isLoading {
                    LoadingPlaceholder()
                } else if memories.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing unresolved", systemImage: "checkmark.circle")
                    } description: {
                        Text("Questions, tasks and reminders Clipper hears will collect here.")
                    }
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(memories) { memory in
                        NavigationLink {
                            MemoryDetailView(memoryID: memory.id)
                        } label: {
                            MemoryRow(memory: memory)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                store.detach { await $0.setMemoryArchived(id: memory.id, archived: true) }
                                memories.removeAll { $0.id == memory.id }
                            } label: {
                                Label("Resolve", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                    }
                }
            } footer: {
                Text("Swipe to mark something resolved. It is archived, not deleted.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Unresolved")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        memories = await store.unresolvedMemories(limit: 80)
        isLoading = false
    }
}

// MARK: - Contradictions

struct ContradictionsView: View {
    @State private var contradictions: [ContradictionDTO] = []
    @State private var showResolved = false
    @State private var isLoading = true

    private let store = ClipperStore.shared

    var body: some View {
        List {
            Section {
                Toggle("Show resolved", isOn: $showResolved)
            } footer: {
                Text("Clipper cannot know which statement is true, so it keeps both and marks both as contradictory. Choosing one is your call.")
            }

            if isLoading {
                LoadingPlaceholder()
            } else if contradictions.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No contradictions", systemImage: "checkmark.seal")
                    } description: {
                        Text("Nothing Clipper has heard conflicts with anything else it has heard.")
                    }
                    .listRowInsets(EdgeInsets())
                }
            } else {
                ForEach(contradictions) { contradiction in
                    Section {
                        Text(contradiction.explanation)
                            .font(.footnote)

                        if let earlier = contradiction.earlier {
                            contradictionSide(memory: earlier, label: "Earlier", contradiction: contradiction)
                        }
                        if let later = contradiction.later {
                            contradictionSide(memory: later, label: "Later", contradiction: contradiction)
                        }
                    } header: {
                        HStack {
                            Text(contradiction.detectedAt.formatted(date: .abbreviated, time: .shortened))
                            if contradiction.isResolved {
                                Text("· resolved").foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Contradictions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: showResolved) { _, _ in Task { await load() } }
    }

    private func contradictionSide(memory: MemoryDTO,
                                   label: String,
                                   contradiction: ContradictionDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(memory.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            NavigationLink {
                MemoryDetailView(memoryID: memory.id)
            } label: {
                MemoryRow(memory: memory)
            }
            if !contradiction.isResolved {
                Button("Keep this one") {
                    store.detach { await $0.resolveContradiction(id: contradiction.id, keeping: memory.id) }
                    Task { try? await Task.sleep(nanoseconds: 300_000_000); await load() }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        contradictions = await store.contradictions(includeResolved: showResolved, limit: 40)
        isLoading = false
    }
}
