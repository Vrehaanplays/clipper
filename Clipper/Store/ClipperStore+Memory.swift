import Foundation
import SwiftData

// The curated-memory and brain-map half of the store.
//
// The rule that shapes all of it: **nothing is overwritten.** A changed fact supersedes its
// predecessor and both stay readable; a conflicting fact creates a contradiction row and
// both are marked; a repeated fact reinforces one row instead of spawning duplicates.

extension ClipperStore {

    // MARK: - Extractions

    func insertExtractions(_ candidates: [ExtractionCandidate],
                           transcriptSegmentID: UUID,
                           conversationID: UUID?,
                           speakerID: UUID?,
                           occurredAt: Date) {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            let record = ExtractionRecord(transcriptSegmentID: transcriptSegmentID,
                                          conversationID: conversationID,
                                          speakerID: speakerID,
                                          kind: candidate.kind,
                                          text: candidate.text,
                                          subject: candidate.subject,
                                          confidence: candidate.confidence,
                                          assertion: candidate.assertion,
                                          occurredAt: occurredAt)
            modelContext.insert(record)
        }
        commit("insertExtractions")
    }

    func extractions(conversationID: UUID, limit: Int = 400) -> [ExtractionSnapshot] {
        var descriptor = FetchDescriptor<ExtractionRecord>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.occurredAt)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.snapshot)
    }

    func extractions(kinds: [MemoryKind], from start: Date, to end: Date, limit: Int = 500) -> [ExtractionSnapshot] {
        let raws = Set(kinds.map(\.rawValue))
        var descriptor = FetchDescriptor<ExtractionRecord>(
            predicate: #Predicate { $0.occurredAt >= start && $0.occurredAt < end },
            sortBy: [SortDescriptor(\.occurredAt)]
        )
        descriptor.fetchLimit = limit * 3
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.filter { raws.contains($0.kindRaw) }.prefix(limit).map(\.snapshot)
    }

    // MARK: - Memories

    /// Create or reinforce a memory.
    ///
    /// Four outcomes, in order of precedence:
    ///
    /// 1. **No existing memory for the key** → insert.
    /// 2. **Same key, same substance** → reinforce: bump `occurrenceCount`, extend
    ///    `lastSeenAt`, union the sources, nudge confidence up. One row, stronger.
    /// 3. **Same key, different substance, `supersedeOnChange`** → insert a new revision
    ///    pointing at the old one, mark the old one superseded, and record a contradiction
    ///    so the change is *visible* rather than silent.
    /// 4. **Same key, different substance, not superseding** → reinforce but append the new
    ///    detail, and downgrade the assertion to `.uncertain` because the evidence
    ///    disagrees with itself.
    @discardableResult
    func upsertMemory(_ candidate: MemoryCandidate) -> MemoryDTO? {
        let trimmedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !candidate.dedupeKey.isEmpty else { return nil }

        let key = candidate.dedupeKey
        var descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.dedupeKey == key && $0.supersededByID == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let existing = (try? modelContext.fetch(descriptor))?.first

        guard let existing else {
            let record = MemoryRecord(kind: candidate.kind,
                                      title: trimmedTitle,
                                      detail: candidate.detail,
                                      confidence: candidate.confidence,
                                      assertion: candidate.sourceIDs.isEmpty ? .unsupported : candidate.assertion,
                                      importance: candidate.importance,
                                      firstSeenAt: candidate.occurredAt,
                                      lastSeenAt: candidate.occurredAt,
                                      occurrenceCount: candidate.occurrences,
                                      sourceKind: candidate.sourceKind,
                                      sourceIDs: candidate.sourceIDs.asStrings,
                                      nodeIDs: candidate.nodeIDs.asStrings,
                                      subjectSpeakerID: candidate.subjectSpeakerID,
                                      dedupeKey: key,
                                      embedding: candidate.embedding.isEmpty
                                          ? nil : VectorMath.encode(candidate.embedding))
            modelContext.insert(record)
            commit("insertMemory")
            return record.dto
        }

        let substanceChanged = Self.isMateriallyDifferent(existing.detail.isEmpty ? existing.title : existing.detail,
                                                          candidate.detail.isEmpty ? trimmedTitle : candidate.detail)

        if substanceChanged && candidate.supersedeOnChange {
            let replacement = MemoryRecord(kind: candidate.kind,
                                           title: trimmedTitle,
                                           detail: candidate.detail,
                                           confidence: candidate.confidence,
                                           assertion: candidate.assertion,
                                           importance: max(existing.importance, candidate.importance),
                                           firstSeenAt: existing.firstSeenAt,
                                           lastSeenAt: candidate.occurredAt,
                                           occurrenceCount: candidate.occurrences,
                                           revision: existing.revision + 1,
                                           supersedesID: existing.id,
                                           sourceKind: candidate.sourceKind,
                                           sourceIDs: candidate.sourceIDs.asStrings,
                                           nodeIDs: candidate.nodeIDs.asStrings,
                                           subjectSpeakerID: candidate.subjectSpeakerID,
                                           dedupeKey: key,
                                           embedding: candidate.embedding.isEmpty
                                               ? nil : VectorMath.encode(candidate.embedding))
            modelContext.insert(replacement)
            existing.supersededByID = replacement.id
            existing.assertion = .contradictory
            existing.updatedAt = Date()

            let contradiction = ContradictionRecord(
                earlierMemoryID: existing.id,
                laterMemoryID: replacement.id,
                explanation: "Earlier: \(existing.title). Later: \(trimmedTitle).",
                confidence: min(existing.confidence, candidate.confidence)
            )
            modelContext.insert(contradiction)
            commit("supersedeMemory")
            Log.database.notice("Memory superseded, revision \(replacement.revision)")
            return replacement.dto
        }

        // Reinforce.
        existing.occurrenceCount += candidate.occurrences
        existing.lastSeenAt = max(existing.lastSeenAt, candidate.occurredAt)
        existing.firstSeenAt = min(existing.firstSeenAt, candidate.occurredAt)
        existing.updatedAt = Date()
        existing.importance = max(existing.importance, candidate.importance)
        // Repetition is weak evidence, so confidence approaches but never reaches 1.
        existing.confidence = min(0.95, existing.confidence + (1 - existing.confidence) * 0.2)

        for source in candidate.sourceIDs.asStrings where !existing.sourceIDs.contains(source) {
            existing.sourceIDs.append(source)
        }
        // A claim repeated for years would otherwise accumulate an unbounded citation list.
        // Keep the earliest sightings, which is what "when did I first say this" needs, and
        // the most recent ones, which is what the evidence view shows.
        if existing.sourceIDs.count > Self.maximumSourcesPerMemory {
            let keepEarliest = 8
            existing.sourceIDs = Array(existing.sourceIDs.prefix(keepEarliest))
                + Array(existing.sourceIDs.suffix(Self.maximumSourcesPerMemory - keepEarliest))
        }
        for node in candidate.nodeIDs.asStrings where !existing.nodeIDs.contains(node) {
            existing.nodeIDs.append(node)
        }

        if substanceChanged {
            if !candidate.detail.isEmpty, !existing.detail.contains(candidate.detail) {
                existing.detail = existing.detail.isEmpty
                    ? candidate.detail
                    : existing.detail + "\n" + candidate.detail
            }
            // The sources no longer agree, and pretending otherwise would be the one thing
            // this app must not do.
            if existing.assertion == .stated || existing.assertion == .summarised {
                existing.assertion = .uncertain
            }
        }

        if existing.sourceIDs.isEmpty { existing.assertion = .unsupported }

        commit("reinforceMemory")
        return existing.dto
    }

    /// Upper bound on the citation list a single memory carries. Enough that the evidence
    /// view is never thin, small enough that a claim repeated for years stays a fixed size.
    static let maximumSourcesPerMemory = 64

    /// Two normalised strings differ enough to count as a different claim.
    ///
    /// Token-overlap rather than equality, so "I'll use Postgres" and "I will use Postgres"
    /// are the same claim while "I'll use Postgres" and "I'll use SQLite" are not.
    static func isMateriallyDifferent(_ a: String, _ b: String) -> Bool {
        let left = Set(Tokenizer.tokens(in: a))
        let right = Set(Tokenizer.tokens(in: b))
        guard !left.isEmpty, !right.isEmpty else { return a != b }
        let overlap = Double(left.intersection(right).count)
        let union = Double(left.union(right).count)
        return (overlap / union) < 0.6
    }

    func memory(id: UUID) -> MemoryDTO? {
        fetchMemory(id)?.dto
    }

    func memories(ids: [UUID]) -> [MemoryDTO] {
        ids.compactMap { fetchMemory($0)?.dto }
    }

    func memories(kinds: [MemoryKind] = [],
                  includeArchived: Bool = false,
                  includeSuperseded: Bool = false,
                  limit: Int = 60,
                  offset: Int = 0) -> [MemoryDTO] {
        var descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        // Over-fetch, then filter in memory: the kind list and the superseded/archived
        // flags are cheap to test and combining them all into one `#Predicate` produces
        // expressions the macro cannot always compile.
        descriptor.fetchLimit = (limit + offset) * 3 + 60
        var records = (try? modelContext.fetch(descriptor)) ?? []

        if !includeArchived { records = records.filter { !$0.isArchived } }
        if !includeSuperseded { records = records.filter { $0.supersededByID == nil } }
        if !kinds.isEmpty {
            let raws = Set(kinds.map(\.rawValue))
            records = records.filter { raws.contains($0.kindRaw) }
        }
        return records.dropFirst(offset).prefix(limit).map(\.dto)
    }

    /// The "recent important memories" query: strength and recency together.
    func importantMemories(limit: Int = 12) -> [MemoryDTO] {
        var descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.supersededByID == nil && $0.isArchived == false },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        let records = (try? modelContext.fetch(descriptor)) ?? []
        let now = Date()
        return records
            .sorted { left, right in
                Self.rank(left, now: now) > Self.rank(right, now: now)
            }
            .prefix(limit)
            .map(\.dto)
    }

    private static func rank(_ memory: MemoryRecord, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(memory.lastSeenAt) / 86_400)
        let recency = 1 / (1 + ageDays / 14)
        return 0.5 * memory.strength + 0.3 * memory.importance + 0.2 * recency
    }

    /// Questions, tasks, reminders and explicitly unresolved items that are still open.
    func unresolvedMemories(limit: Int = 60) -> [MemoryDTO] {
        memories(kinds: MemoryKind.unresolvedKinds, limit: limit)
    }

    /// Every revision of one memory, oldest first — the "what changed" view.
    func revisionChain(for id: UUID) -> [MemoryDTO] {
        guard let start = fetchMemory(id) else { return [] }

        var backwards: [MemoryRecord] = []
        var cursor: MemoryRecord? = start
        var guardCount = 0
        while let current = cursor, guardCount < 64 {
            backwards.append(current)
            cursor = current.supersedesID.flatMap { fetchMemory($0) }
            guardCount += 1
        }

        var forwards: [MemoryRecord] = []
        cursor = start.supersededByID.flatMap { fetchMemory($0) }
        guardCount = 0
        while let current = cursor, guardCount < 64 {
            forwards.append(current)
            cursor = current.supersededByID.flatMap { fetchMemory($0) }
            guardCount += 1
        }

        return (backwards.reversed() + forwards).map(\.dto)
    }

    func setMemoryArchived(id: UUID, archived: Bool) {
        guard let record = fetchMemory(id) else { return }
        record.isArchived = archived
        record.updatedAt = Date()
        commit("setMemoryArchived")
    }

    /// A user correction. Written as a new revision, never as an edit in place, so the
    /// machine's original claim stays auditable.
    @discardableResult
    func editMemory(id: UUID, title: String, detail: String) -> MemoryDTO? {
        guard let existing = fetchMemory(id) else { return nil }
        let replacement = MemoryRecord(kind: existing.kind,
                                       title: title,
                                       detail: detail,
                                       confidence: 1,
                                       assertion: .stated,
                                       importance: existing.importance,
                                       firstSeenAt: existing.firstSeenAt,
                                       lastSeenAt: Date(),
                                       occurrenceCount: existing.occurrenceCount,
                                       revision: existing.revision + 1,
                                       supersedesID: existing.id,
                                       isUserEdited: true,
                                       sourceKind: existing.sourceKind,
                                       sourceIDs: existing.sourceIDs,
                                       nodeIDs: existing.nodeIDs,
                                       subjectSpeakerID: existing.subjectSpeakerID,
                                       dedupeKey: existing.dedupeKey,
                                       embedding: existing.embedding)
        modelContext.insert(replacement)
        existing.supersededByID = replacement.id
        existing.updatedAt = Date()
        commit("editMemory")
        return replacement.dto
    }

    func deleteMemory(id: UUID) {
        guard let record = fetchMemory(id) else { return }
        modelContext.delete(record)
        commit("deleteMemory")
    }

    /// Memories whose provenance list contains a given id — "what did this line become?".
    ///
    /// `sourceIDs` is a stored array, which `#Predicate` cannot search, so this over-fetches
    /// a bounded page by recency and filters in memory. That is a deliberate trade: adding a
    /// join table to make this one screen a single query would cost a row per citation on
    /// every write.
    func memoriesCiting(sourceID: UUID, limit: Int = 20) -> [MemoryDTO] {
        let key = sourceID.uuidString
        var descriptor = FetchDescriptor<MemoryRecord>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 600
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records
            .filter { $0.sourceIDs.contains(key) }
            .prefix(limit)
            .map(\.dto)
    }

    /// Other memories that share a node with this one — the "connected memories" list.
    func relatedMemories(to memoryID: UUID, limit: Int = 12) -> [MemoryDTO] {
        guard let memory = fetchMemory(memoryID) else { return [] }
        let nodeKeys = Set(memory.nodeIDs)
        guard !nodeKeys.isEmpty else { return [] }

        var descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.supersededByID == nil && $0.isArchived == false },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 400
        let records = (try? modelContext.fetch(descriptor)) ?? []

        return records
            .filter { $0.id != memoryID && !Set($0.nodeIDs).intersection(nodeKeys).isEmpty }
            // Most shared nodes first: that is what "related" means here, and it is
            // explainable rather than a similarity score the user cannot check.
            .sorted { Set($0.nodeIDs).intersection(nodeKeys).count > Set($1.nodeIDs).intersection(nodeKeys).count }
            .prefix(limit)
            .map(\.dto)
    }

    /// Memories attached to one brain-map node.
    func memories(nodeID: UUID, limit: Int = 40) -> [MemoryDTO] {
        let key = nodeID.uuidString
        var descriptor = FetchDescriptor<MemoryRecord>(
            predicate: #Predicate { $0.supersededByID == nil && $0.isArchived == false },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.filter { $0.nodeIDs.contains(key) }.prefix(limit).map(\.dto)
    }

    func fetchMemory(_ id: UUID) -> MemoryRecord? {
        var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Contradictions

    func contradictions(includeResolved: Bool = false, limit: Int = 40) -> [ContradictionDTO] {
        var descriptor = FetchDescriptor<ContradictionRecord>(
            sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 2
        var records = (try? modelContext.fetch(descriptor)) ?? []
        if !includeResolved { records = records.filter { !$0.isResolved } }
        return records.prefix(limit).map { record in
            ContradictionDTO(id: record.id,
                             explanation: record.explanation,
                             detectedAt: record.detectedAt,
                             confidence: record.confidence,
                             isResolved: record.isResolved,
                             earlier: fetchMemory(record.earlierMemoryID)?.dto,
                             later: fetchMemory(record.laterMemoryID)?.dto)
        }
    }

    /// Record a conflict between two memories that are not in a supersede chain — two
    /// claims about the same subject that cannot both hold.
    func recordContradiction(earlier: UUID, later: UUID, explanation: String, confidence: Double) {
        var descriptor = FetchDescriptor<ContradictionRecord>(
            predicate: #Predicate { $0.earlierMemoryID == earlier && $0.laterMemoryID == later }
        )
        descriptor.fetchLimit = 1
        guard (try? modelContext.fetch(descriptor))?.first == nil else { return }

        modelContext.insert(ContradictionRecord(earlierMemoryID: earlier,
                                                laterMemoryID: later,
                                                explanation: explanation,
                                                confidence: confidence))
        if let a = fetchMemory(earlier) { a.assertion = .contradictory }
        if let b = fetchMemory(later) { b.assertion = .contradictory }
        commit("recordContradiction")
    }

    /// The user picked a side. The loser is archived, not deleted.
    func resolveContradiction(id: UUID, keeping memoryID: UUID?) {
        var descriptor = FetchDescriptor<ContradictionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        record.isResolved = true
        record.resolvedAt = Date()
        record.keptMemoryID = memoryID

        if let memoryID {
            let loser = memoryID == record.earlierMemoryID ? record.laterMemoryID : record.earlierMemoryID
            if let kept = fetchMemory(memoryID) {
                kept.assertion = .stated
                kept.confidence = max(kept.confidence, 0.9)
                kept.updatedAt = Date()
            }
            if let archived = fetchMemory(loser) {
                archived.isArchived = true
                archived.updatedAt = Date()
            }
        }
        commit("resolveContradiction")
    }

    // MARK: - Summaries

    /// Idempotent by `scope` + `key`: regenerating a day updates one row and bumps its
    /// revision rather than accumulating opinions.
    @discardableResult
    func upsertSummary(scope: SummaryScope,
                       key: String,
                       draft: SummaryDraft,
                       periodStart: Date,
                       periodEnd: Date,
                       sourceKind: SourceKind,
                       sourceIDs: [UUID],
                       embedding: [Float] = []) -> SummaryDTO {
        let scopeRaw = scope.rawValue
        var descriptor = FetchDescriptor<SummaryRecord>(
            predicate: #Predicate { $0.scopeRaw == scopeRaw && $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = draft.title
            existing.text = draft.text
            existing.bullets = draft.bullets
            existing.updatedAt = Date()
            existing.revision += 1
            existing.periodStart = periodStart
            existing.periodEnd = periodEnd
            existing.confidence = draft.confidence
            existing.sourceKind = sourceKind
            existing.sourceIDs = sourceIDs.asStrings
            existing.generator = draft.generator
            existing.assertion = sourceIDs.isEmpty ? .unsupported : .summarised
            if !embedding.isEmpty { existing.embedding = VectorMath.encode(embedding) }
            commit("updateSummary")
            return existing.dto
        }

        let record = SummaryRecord(scope: scope,
                                   key: key,
                                   title: draft.title,
                                   text: draft.text,
                                   bullets: draft.bullets,
                                   periodStart: periodStart,
                                   periodEnd: periodEnd,
                                   confidence: draft.confidence,
                                   assertion: sourceIDs.isEmpty ? .unsupported : .summarised,
                                   sourceKind: sourceKind,
                                   sourceIDs: sourceIDs.asStrings,
                                   generator: draft.generator,
                                   embedding: embedding.isEmpty ? nil : VectorMath.encode(embedding))
        modelContext.insert(record)
        commit("insertSummary")
        return record.dto
    }

    func summary(id: UUID) -> SummaryDTO? {
        fetchSummary(id)?.dto
    }

    func summary(scope: SummaryScope, key: String) -> SummaryDTO? {
        let scopeRaw = scope.rawValue
        var descriptor = FetchDescriptor<SummaryRecord>(
            predicate: #Predicate { $0.scopeRaw == scopeRaw && $0.key == key }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first)?.dto
    }

    func summaries(scope: SummaryScope? = nil, limit: Int = 40, offset: Int = 0) -> [SummaryDTO] {
        var descriptor = FetchDescriptor<SummaryRecord>(
            sortBy: [SortDescriptor(\.periodStart, order: .reverse)]
        )
        descriptor.fetchLimit = (limit + offset) * 2 + 20
        var records = (try? modelContext.fetch(descriptor)) ?? []
        if let scope {
            let raw = scope.rawValue
            records = records.filter { $0.scopeRaw == raw }
        }
        return records.dropFirst(offset).prefix(limit).map(\.dto)
    }

    /// The single most recent summary of any scope — what the widget shows.
    func latestSummary() -> SummaryDTO? {
        var descriptor = FetchDescriptor<SummaryRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first)?.dto
    }

    func fetchSummary(_ id: UUID) -> SummaryRecord? {
        var descriptor = FetchDescriptor<SummaryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Brain map

    /// Find or create a node. `normalizedName` is the identity, so casing and articles do
    /// not fragment one topic into five nodes.
    @discardableResult
    func upsertNode(kind: NodeKind,
                    name: String,
                    refID: UUID? = nil,
                    refKind: SourceKind? = nil,
                    importanceFloor: Double = 0,
                    mentionedAt: Date = Date(),
                    embedding: [Float] = []) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let normalized = Tokenizer.normalizeName(trimmed)
        guard !normalized.isEmpty else { return nil }

        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<GraphNodeRecord>(
            predicate: #Predicate { $0.normalizedName == normalized && $0.kindRaw == kindRaw }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.mentionCount += 1
            existing.lastMentionedAt = max(existing.lastMentionedAt, mentionedAt)
            existing.updatedAt = Date()
            existing.importance = max(existing.importance,
                                      max(importanceFloor, min(1, Double(existing.mentionCount) / 25)))
            if existing.refID == nil, let refID {
                existing.refID = refID
                existing.refKind = refKind
            }
            if existing.embedding == nil, !embedding.isEmpty {
                existing.embedding = VectorMath.encode(embedding)
            }
            commit("bumpNode")
            return existing.id
        }

        let record = GraphNodeRecord(kind: kind,
                                     name: trimmed,
                                     normalizedName: normalized,
                                     lastMentionedAt: mentionedAt,
                                     importance: max(importanceFloor, 0.1),
                                     refID: refID,
                                     refKind: refKind,
                                     embedding: embedding.isEmpty ? nil : VectorMath.encode(embedding))
        modelContext.insert(record)
        commit("insertNode")
        return record.id
    }

    /// Add to an edge or create it. Weight accumulates, so repeated co-occurrence is what
    /// makes a relationship prominent in the map.
    func upsertEdge(source: UUID,
                    target: UUID,
                    kind: EdgeKind,
                    weightDelta: Double = 1,
                    confidence: Double = 0.5,
                    evidenceIDs: [UUID] = [],
                    evidenceKind: SourceKind = .transcriptSegment) {
        guard source != target else { return }
        let kindRaw = kind.rawValue
        var descriptor = FetchDescriptor<GraphEdgeRecord>(
            predicate: #Predicate {
                $0.sourceNodeID == source && $0.targetNodeID == target && $0.kindRaw == kindRaw
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.weight += weightDelta
            existing.confidence = max(existing.confidence, confidence)
            existing.updatedAt = Date()
            // Cap the evidence list: an edge needs enough to be explainable, not every
            // instance for the life of the app.
            for id in evidenceIDs.asStrings where !existing.evidenceIDs.contains(id) {
                if existing.evidenceIDs.count >= 24 { break }
                existing.evidenceIDs.append(id)
            }
            commit("bumpEdge")
            return
        }

        let record = GraphEdgeRecord(sourceNodeID: source,
                                     targetNodeID: target,
                                     kind: kind,
                                     weight: weightDelta,
                                     confidence: confidence,
                                     evidenceIDs: Array(evidenceIDs.asStrings.prefix(24)),
                                     evidenceKind: evidenceKind)
        modelContext.insert(record)
        commit("insertEdge")
    }

    func node(id: UUID) -> GraphNodeDTO? {
        fetchNode(id)?.dto
    }

    func nodes(kind: NodeKind? = nil, limit: Int = 60, offset: Int = 0) -> [GraphNodeDTO] {
        var descriptor = FetchDescriptor<GraphNodeRecord>(
            sortBy: [SortDescriptor(\.mentionCount, order: .reverse),
                     SortDescriptor(\.lastMentionedAt, order: .reverse)]
        )
        descriptor.fetchLimit = (limit + offset) * 3 + 30
        var records = (try? modelContext.fetch(descriptor)) ?? []
        if let kind {
            let raw = kind.rawValue
            records = records.filter { $0.kindRaw == raw }
        }
        return records.dropFirst(offset).prefix(limit).map(\.dto)
    }

    func nodes(matching query: String, limit: Int = 20) -> [GraphNodeDTO] {
        let normalized = Tokenizer.normalizeName(query)
        guard !normalized.isEmpty else { return [] }
        var descriptor = FetchDescriptor<GraphNodeRecord>(
            predicate: #Predicate { $0.normalizedName.contains(normalized) },
            sortBy: [SortDescriptor(\.mentionCount, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.dto)
    }

    /// One node and its strongest neighbours. **Never the whole graph** — the brain map
    /// renders a focused subgraph and expands on demand, which is what keeps it usable
    /// after years of data.
    func subgraph(around nodeID: UUID, maxNeighbours: Int = 12, minWeight: Double = 1) -> SubgraphDTO? {
        guard let focus = fetchNode(nodeID) else { return nil }

        var outgoing = FetchDescriptor<GraphEdgeRecord>(
            predicate: #Predicate { $0.sourceNodeID == nodeID },
            sortBy: [SortDescriptor(\.weight, order: .reverse)]
        )
        outgoing.fetchLimit = maxNeighbours * 2
        var incoming = FetchDescriptor<GraphEdgeRecord>(
            predicate: #Predicate { $0.targetNodeID == nodeID },
            sortBy: [SortDescriptor(\.weight, order: .reverse)]
        )
        incoming.fetchLimit = maxNeighbours * 2

        let edges = (((try? modelContext.fetch(outgoing)) ?? [])
                     + ((try? modelContext.fetch(incoming)) ?? []))
            .filter { $0.weight >= minWeight }
            .sorted { $0.weight > $1.weight }

        var seen = Set<UUID>([nodeID])
        var neighbours: [GraphNodeRecord] = []
        var kept: [GraphEdgeRecord] = []
        var truncated = false

        for edge in edges {
            let otherID = edge.sourceNodeID == nodeID ? edge.targetNodeID : edge.sourceNodeID
            if seen.contains(otherID) {
                kept.append(edge)
                continue
            }
            if neighbours.count >= maxNeighbours {
                truncated = true
                break
            }
            guard let other = fetchNode(otherID) else { continue }
            seen.insert(otherID)
            neighbours.append(other)
            kept.append(edge)
        }

        return SubgraphDTO(focus: focus.dto,
                           neighbours: neighbours.map(\.dto),
                           edges: kept.map(\.dto),
                           hasMore: truncated)
    }

    func setNodeSummary(nodeID: UUID, summaryID: UUID) {
        guard let node = fetchNode(nodeID) else { return }
        node.summaryID = summaryID
        node.updatedAt = Date()
        commit("setNodeSummary")
    }

    /// The conversations that mention a node, via the edges that cite them.
    func evidenceIDs(forEdge edgeID: UUID) -> (ids: [UUID], kind: SourceKind) {
        var descriptor = FetchDescriptor<GraphEdgeRecord>(predicate: #Predicate { $0.id == edgeID })
        descriptor.fetchLimit = 1
        guard let edge = try? modelContext.fetch(descriptor).first else { return ([], .transcriptSegment) }
        return (edge.evidenceIDs.asUUIDs, edge.evidenceKind)
    }

    func fetchNode(_ id: UUID) -> GraphNodeRecord? {
        var descriptor = FetchDescriptor<GraphNodeRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

/// A value-type view of an extraction, for the pipeline stages that aggregate them.
struct ExtractionSnapshot: Hashable, Sendable {
    let id: UUID
    let transcriptSegmentID: UUID
    let conversationID: UUID?
    let speakerID: UUID?
    let kind: MemoryKind
    let text: String
    let subject: String?
    let confidence: Double
    let assertion: AssertionKind
    let occurredAt: Date
}

extension ExtractionRecord {
    var snapshot: ExtractionSnapshot {
        ExtractionSnapshot(id: id,
                           transcriptSegmentID: transcriptSegmentID,
                           conversationID: conversationID,
                           speakerID: speakerID,
                           kind: kind,
                           text: text,
                           subject: subject,
                           confidence: confidence,
                           assertion: assertion,
                           occurredAt: occurredAt)
    }
}
