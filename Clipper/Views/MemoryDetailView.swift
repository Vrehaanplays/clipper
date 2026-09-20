import SwiftUI

/// One curated memory, its evidence, its history and what it connects to.
struct MemoryDetailView: View {
    let memoryID: UUID

    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var memory: MemoryDTO?
    @State private var revisions: [MemoryDTO] = []
    @State private var evidence: [TranscriptLineDTO] = []
    @State private var related: [MemoryDTO] = []
    @State private var nodes: [GraphNodeDTO] = []
    @State private var isLoading = true
    @State private var isEditing = false

    private let store = ClipperStore.shared

    var body: some View {
        List {
            if isLoading {
                LoadingPlaceholder()
            } else if let memory {
                headerSection(memory)
                evidenceSection(memory)
                historySection(memory)
                connectionsSection
                actionsSection(memory)
            } else {
                ContentUnavailableView("Memory not found",
                                       systemImage: "questionmark.folder",
                                       description: Text("It may have been deleted."))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(memory?.kind.title ?? "Memory")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditing) {
            if let memory {
                MemoryEditSheet(memory: memory) { await load() }
            }
        }
        .task { await load() }
        .onChange(of: pipeline.revision) { _, _ in Task { await load() } }
    }

    // MARK: - Sections

    private func headerSection(_ memory: MemoryDTO) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(memory.title)
                    .font(.title3.weight(.semibold))

                if !memory.detail.isEmpty, memory.detail != memory.title {
                    Text(memory.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    KindTag(symbolName: memory.kind.symbolName, title: memory.kind.title)
                    AssertionBadge(assertion: memory.assertion, confidence: memory.confidence)
                    if memory.isUserEdited {
                        KindTag(symbolName: "pencil", title: "Yours", tint: .blue)
                    }
                }

                if memory.isUnsupported {
                    Label("No source is recorded for this memory. Treat it as unsupported.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if memory.supersededByID != nil {
                    Label("A later statement supersedes this one.", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text(footerText(memory))
        }
    }

    private func footerText(_ memory: MemoryDTO) -> String {
        var parts = ["First heard \(memory.firstSeenAt.formatted(date: .abbreviated, time: .shortened))"]
        if memory.occurrenceCount > 1 {
            parts.append("mentioned \(memory.occurrenceCount) times")
        }
        parts.append("last \(memory.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
        return parts.joined(separator: " · ")
    }

    private func evidenceSection(_ memory: MemoryDTO) -> some View {
        Section {
            if evidence.isEmpty {
                Text(memory.sourceKind == .summary
                     ? "Backed by a summary, which is itself backed by transcript lines."
                     : "No transcript lines could be resolved for this memory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence) { line in
                    NavigationLink {
                        EvidenceDetailView(line: line, conversation: nil, summary: nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text)
                                .font(.footnote)
                                .lineLimit(3)
                            HStack(spacing: 6) {
                                SpeakerChip(label: line.speakerLabel,
                                            colorIndex: line.speakerColorIndex,
                                            isUnknown: line.speakerIsUnknown)
                                Text(line.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 4)
                                if !line.audioAvailable {
                                    Image(systemName: "waveform.slash")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Evidence")
        } footer: {
            Text("\(memory.sourceIDs.count) source\(memory.sourceIDs.count == 1 ? "" : "s") recorded.")
        }
    }

    @ViewBuilder
    private func historySection(_ memory: MemoryDTO) -> some View {
        if revisions.count > 1 {
            Section {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 2) {
                            Text("\(revision.revision)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            if index < revisions.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 1, height: 16)
                            }
                        }
                        .frame(width: 18)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(revision.title)
                                .font(.footnote)
                                .foregroundStyle(revision.id == memory.id ? .primary : .secondary)
                            HStack(spacing: 6) {
                                Text(revision.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                if revision.id == memory.id { Text("· shown above") }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("How this changed")
            } footer: {
                Text("Clipper never overwrites a memory. Each revision is kept, so what you said earlier stays readable.")
            }
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        if !nodes.isEmpty || !related.isEmpty {
            Section("Connected") {
                if !nodes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(nodes) { node in
                                NavigationLink {
                                    BrainMapView(focusNodeID: node.id)
                                } label: {
                                    KindTag(symbolName: node.kind.symbolName, title: node.name, tint: .indigo)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                ForEach(related) { other in
                    NavigationLink {
                        MemoryDetailView(memoryID: other.id)
                    } label: {
                        MemoryRow(memory: other)
                    }
                }
            }
        }
    }

    private func actionsSection(_ memory: MemoryDTO) -> some View {
        Section {
            Button {
                isEditing = true
            } label: {
                Label("Correct this memory", systemImage: "pencil")
            }

            Button {
                store.detach { await $0.setMemoryArchived(id: memory.id, archived: !memory.isArchived) }
                Task { try? await Task.sleep(nanoseconds: 250_000_000); await load() }
            } label: {
                Label(memory.isArchived ? "Unarchive" : "Archive",
                      systemImage: memory.isArchived ? "tray.and.arrow.up" : "archivebox")
            }

            Button(role: .destructive) {
                store.detach { store in
                    await store.deleteMemory(id: memory.id)
                    await store.removeDocument(refID: memory.id)
                }
                Task {
                    await SpotlightIndexer.shared.remove(links: [.memory(memory.id)])
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } footer: {
            Text("A correction is stored as a new revision, so the machine's original claim stays auditable. Deleting removes the memory but not the transcript it came from.")
        }
    }

    // MARK: - Load

    private func load() async {
        let loaded = await store.memory(id: memoryID)
        memory = loaded
        guard let loaded else {
            isLoading = false
            return
        }
        revisions = await store.revisionChain(for: memoryID)
        evidence = await store.transcriptLines(ids: loaded.sourceIDs)
        related = await store.relatedMemories(to: memoryID)
        var loadedNodes: [GraphNodeDTO] = []
        for nodeID in loaded.nodeIDs.prefix(8) {
            if let node = await store.node(id: nodeID) { loadedNodes.append(node) }
        }
        nodes = loadedNodes
        isLoading = false
    }
}

// MARK: - Row

struct MemoryRow: View {
    let memory: MemoryDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: memory.kind.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(memory.title)
                    .font(.subheadline)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                AssertionBadge(assertion: memory.assertion, confidence: memory.confidence, compact: true)
                Text(memory.lastSeenAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if memory.occurrenceCount > 1 {
                    Text("· ×\(memory.occurrenceCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if memory.revision > 1 {
                    Text("· rev \(memory.revision)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                ScoreBar(value: memory.strength, width: 28)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Edit

struct MemoryEditSheet: View {
    let memory: MemoryDTO
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var detail: String

    private let store = ClipperStore.shared

    init(memory: MemoryDTO, onSave: @escaping () async -> Void) {
        self.memory = memory
        self.onSave = onSave
        _title = State(initialValue: memory.title)
        _detail = State(initialValue: memory.detail)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                }
                Section {
                    TextEditor(text: $detail)
                        .frame(minHeight: 100)
                } header: {
                    Text("Detail")
                } footer: {
                    Text("Saved as revision \(memory.revision + 1). The previous version is kept and marked as superseded by yours.")
                }
            }
            .navigationTitle("Correct memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newDetail = detail
                        dismiss()
                        Task.detached(priority: .userInitiated) {
                            await store.editMemory(id: memory.id, title: newTitle, detail: newDetail)
                            await onSave()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
