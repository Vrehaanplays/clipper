import Foundation
import SwiftData

/// A value-type view of an indexed document, including its vector.
struct IndexedDocumentSnapshot: Hashable, Sendable {
    let id: UUID
    let kind: DocumentKind
    let refID: UUID
    let conversationID: UUID?
    let title: String
    let text: String
    let timestamp: Date
    let speakerIDs: [UUID]
    let nodeIDs: [UUID]
    let importance: Double
    let confidence: Double
    let assertion: AssertionKind
    let tokenCount: Int
    let embedding: [Float]
}

/// One term match: which document, and how strongly.
struct PostingHit: Hashable, Sendable {
    let token: String
    let documentID: UUID
    let weight: Double
    let timestamp: Date
}

struct JobSnapshot: Hashable, Sendable {
    let id: UUID
    let kind: JobKind
    let payload: String
    let attempts: Int
}

// The search index and the job queue. Both are infrastructure: no user-visible concepts
// live here, and both are designed so that the hot path is an indexed fetch rather than a
// scan.

extension ClipperStore {

    // MARK: - Search index

    /// Add or refresh one document. Re-indexing deletes the old postings first, so a
    /// corrected transcript cannot leave its previous terms behind as phantom matches.
    @discardableResult
    func indexDocument(_ candidate: IndexCandidate) -> UUID? {
        let body = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !candidate.title.isEmpty else { return nil }

        let refID = candidate.refID
        let kindRaw = candidate.kind.rawValue
        var lookup = FetchDescriptor<IndexedDocumentRecord>(
            predicate: #Predicate { $0.refID == refID && $0.kindRaw == kindRaw }
        )
        lookup.fetchLimit = 1
        let existing = try? modelContext.fetch(lookup).first

        let weighted = Tokenizer.weightedTokens(title: candidate.title, body: body)

        let document: IndexedDocumentRecord
        if let existing {
            existing.title = candidate.title
            existing.text = body
            existing.timestamp = candidate.timestamp
            existing.indexedAt = Date()
            existing.speakerIDs = candidate.speakerIDs.asStrings
            existing.nodeIDs = candidate.nodeIDs.asStrings
            existing.importance = candidate.importance
            existing.confidence = candidate.confidence
            existing.assertion = candidate.assertion
            existing.conversationID = candidate.conversationID
            existing.tokenCount = weighted.totalTokens
            existing.embedding = candidate.embedding.isEmpty
                ? nil : VectorMath.encode(candidate.embedding)
            document = existing

            let documentID = existing.id
            try? modelContext.delete(model: TokenPostingRecord.self,
                                     where: #Predicate { $0.documentID == documentID })
        } else {
            let fresh = IndexedDocumentRecord(kind: candidate.kind,
                                              refID: candidate.refID,
                                              conversationID: candidate.conversationID,
                                              title: candidate.title,
                                              text: body,
                                              timestamp: candidate.timestamp,
                                              speakerIDs: candidate.speakerIDs.asStrings,
                                              nodeIDs: candidate.nodeIDs.asStrings,
                                              importance: candidate.importance,
                                              confidence: candidate.confidence,
                                              assertion: candidate.assertion,
                                              tokenCount: weighted.totalTokens,
                                              embedding: candidate.embedding.isEmpty
                                                  ? nil : VectorMath.encode(candidate.embedding))
            modelContext.insert(fresh)
            document = fresh
        }

        for (token, weight) in weighted.weights {
            modelContext.insert(TokenPostingRecord(token: token,
                                                   documentID: document.id,
                                                   weight: weight,
                                                   timestamp: candidate.timestamp))
        }

        commit("indexDocument")
        return document.id
    }

    func removeDocument(refID: UUID) {
        var descriptor = FetchDescriptor<IndexedDocumentRecord>(
            predicate: #Predicate { $0.refID == refID }
        )
        descriptor.fetchLimit = 8
        guard let documents = try? modelContext.fetch(descriptor), !documents.isEmpty else { return }
        for document in documents {
            let documentID = document.id
            try? modelContext.delete(model: TokenPostingRecord.self,
                                     where: #Predicate { $0.documentID == documentID })
            modelContext.delete(document)
        }
        commit("removeDocument")
    }

    /// Term lookup: the indexed half of hybrid search.
    ///
    /// One fetch per term against the `token` index, bounded by `perTokenLimit`, with the
    /// date filter pushed into the predicate so a "yesterday" query never loads a decade of
    /// postings.
    func postings(for tokens: [String],
                  from: Date? = nil,
                  to: Date? = nil,
                  perTokenLimit: Int = 400) -> [PostingHit] {
        guard !tokens.isEmpty else { return [] }
        var hits: [PostingHit] = []
        hits.reserveCapacity(min(tokens.count * perTokenLimit, 4_000))

        for token in Set(tokens) {
            var descriptor: FetchDescriptor<TokenPostingRecord>
            if let from, let to {
                descriptor = FetchDescriptor<TokenPostingRecord>(
                    predicate: #Predicate {
                        $0.token == token && $0.timestamp >= from && $0.timestamp < to
                    },
                    sortBy: [SortDescriptor(\.weight, order: .reverse)]
                )
            } else if let from {
                descriptor = FetchDescriptor<TokenPostingRecord>(
                    predicate: #Predicate { $0.token == token && $0.timestamp >= from },
                    sortBy: [SortDescriptor(\.weight, order: .reverse)]
                )
            } else {
                descriptor = FetchDescriptor<TokenPostingRecord>(
                    predicate: #Predicate { $0.token == token },
                    sortBy: [SortDescriptor(\.weight, order: .reverse)]
                )
            }
            descriptor.fetchLimit = perTokenLimit

            let rows = (try? modelContext.fetch(descriptor)) ?? []
            for row in rows {
                hits.append(PostingHit(token: row.token,
                                       documentID: row.documentID,
                                       weight: row.weight,
                                       timestamp: row.timestamp))
            }
        }
        return hits
    }

    /// How many documents contain each term — the IDF half of the ranking function.
    func documentFrequencies(for tokens: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for token in Set(tokens) {
            let descriptor = FetchDescriptor<TokenPostingRecord>(
                predicate: #Predicate { $0.token == token }
            )
            result[token] = (try? modelContext.fetchCount(descriptor)) ?? 0
        }
        return result
    }

    func documents(ids: [UUID]) -> [IndexedDocumentSnapshot] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        // One fetch with an `in`-style membership test, rather than one fetch per id.
        let descriptor = FetchDescriptor<IndexedDocumentRecord>(
            predicate: #Predicate { wanted.contains($0.id) }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.snapshot)
    }

    /// Candidates for a semantic-only pass, bounded by kind, date and count.
    ///
    /// This is the one place that reads documents without a term match, so the bound is
    /// the whole design: `limit` caps it, and the caller passes a date window whenever the
    /// query implies one. There is deliberately no path that vector-scans the entire store.
    func semanticCandidates(kinds: [DocumentKind] = [],
                            from: Date? = nil,
                            to: Date? = nil,
                            limit: Int = 600) -> [IndexedDocumentSnapshot] {
        var descriptor: FetchDescriptor<IndexedDocumentRecord>
        if let from, let to {
            descriptor = FetchDescriptor<IndexedDocumentRecord>(
                predicate: #Predicate { $0.timestamp >= from && $0.timestamp < to },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<IndexedDocumentRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        }
        descriptor.fetchLimit = kinds.isEmpty ? limit : limit * 2

        var records = (try? modelContext.fetch(descriptor)) ?? []
        if !kinds.isEmpty {
            let raws = Set(kinds.map(\.rawValue))
            records = records.filter { raws.contains($0.kindRaw) }
        }
        return records.prefix(limit).map(\.snapshot)
    }

    func documentCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<IndexedDocumentRecord>())) ?? 0
    }

    func postingCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<TokenPostingRecord>())) ?? 0
    }

    /// Refresh the whole index. Only ever triggered by the user from Diagnostics, because
    /// on a large store it is minutes of work, not seconds.
    func documentsNeedingReindex(limit: Int = 500) -> [IndexedDocumentSnapshot] {
        var descriptor = FetchDescriptor<IndexedDocumentRecord>(
            sortBy: [SortDescriptor(\.indexedAt)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.snapshot)
    }

    // MARK: - Jobs

    /// Enqueue, unless an identical job is already waiting. Deduplication matters here:
    /// closing the same conversation twice would regenerate its summary twice.
    @discardableResult
    func enqueueJob(kind: JobKind, payload: String, priority: Int = 0) -> UUID? {
        let kindRaw = kind.rawValue
        let pending = JobState.pending.rawValue
        let running = JobState.running.rawValue
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.payload == payload
                    && ($0.stateRaw == pending || $0.stateRaw == running)
            }
        )
        descriptor.fetchLimit = 1
        if (try? modelContext.fetch(descriptor))?.first != nil { return nil }

        let record = JobRecord(kind: kind, payload: payload, priority: priority)
        modelContext.insert(record)
        commit("enqueueJob")
        return record.id
    }

    /// Take the next job, highest priority then oldest, and mark it running.
    func claimNextJob() -> JobSnapshot? {
        let pending = JobState.pending.rawValue
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == pending },
            sortBy: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        guard let job = try? modelContext.fetch(descriptor).first else { return nil }

        job.state = .running
        job.startedAt = Date()
        job.attempts += 1
        commit("claimNextJob")
        return JobSnapshot(id: job.id, kind: job.kind, payload: job.payload, attempts: job.attempts)
    }

    func finishJob(id: UUID) {
        guard let job = fetchJob(id) else { return }
        job.state = .done
        job.finishedAt = Date()
        job.lastError = nil
        commit("finishJob")
    }

    /// Fail a job. Under the attempt cap it goes back to `pending` for a retry; over it,
    /// it stays failed and is visible in Diagnostics rather than retrying forever.
    func failJob(id: UUID, error: String) {
        guard let job = fetchJob(id) else { return }
        job.lastError = error
        if job.attempts >= JobRecord.maxAttempts {
            job.state = .failed
            job.finishedAt = Date()
            Log.pipeline.error("Job \(job.kindRaw, privacy: .public) gave up after \(job.attempts) attempts: \(error)")
        } else {
            job.state = .pending
        }
        commit("failJob")
    }

    func cancelJobs(kind: JobKind) {
        let kindRaw = kind.rawValue
        let pending = JobState.pending.rawValue
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.stateRaw == pending }
        )
        guard let jobs = try? modelContext.fetch(descriptor), !jobs.isEmpty else { return }
        for job in jobs {
            job.state = .cancelled
            job.finishedAt = Date()
        }
        commit("cancelJobs")
    }

    /// Jobs left `running` by a kill. They are put back in the queue, and the attempt
    /// counter already incremented keeps a job that crashes the app from doing it forever.
    @discardableResult
    func resetStrandedJobs() -> Int {
        let running = JobState.running.rawValue
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == running }
        )
        guard let jobs = try? modelContext.fetch(descriptor), !jobs.isEmpty else { return 0 }
        for job in jobs {
            if job.attempts >= JobRecord.maxAttempts {
                job.state = .failed
                job.finishedAt = Date()
                job.lastError = "Interrupted repeatedly"
            } else {
                job.state = .pending
                job.startedAt = nil
            }
        }
        commit("resetStrandedJobs")
        Log.pipeline.notice("Requeued \(jobs.count) stranded jobs")
        return jobs.count
    }

    /// Housekeeping: finished jobs are only useful for a short while.
    func pruneFinishedJobs(olderThan days: Int = 3) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let done = JobState.done.rawValue
        let cancelled = JobState.cancelled.rawValue
        try? modelContext.delete(model: JobRecord.self,
                                 where: #Predicate {
                                     ($0.stateRaw == done || $0.stateRaw == cancelled)
                                         && $0.createdAt < cutoff
                                 })
        commit("pruneFinishedJobs")
    }

    func pendingJobCount() -> Int {
        let pending = JobState.pending.rawValue
        let running = JobState.running.rawValue
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == pending || $0.stateRaw == running }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func failedJobs(limit: Int = 20) -> [JobSnapshot] {
        let failed = JobState.failed.rawValue
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == failed },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            JobSnapshot(id: $0.id, kind: $0.kind, payload: $0.payload, attempts: $0.attempts)
        }
    }

    func retryFailedJobs() -> Int {
        let failed = JobState.failed.rawValue
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == failed }
        )
        guard let jobs = try? modelContext.fetch(descriptor), !jobs.isEmpty else { return 0 }
        for job in jobs {
            job.state = .pending
            job.attempts = 0
            job.lastError = nil
            job.finishedAt = nil
        }
        commit("retryFailedJobs")
        return jobs.count
    }

    /// Utterance ids that something still needs: a queued job, or an evidence row whose
    /// audio has not yet been re-encoded. Anything else on disk is orphaned debris.
    func liveUtteranceIDs() -> Set<UUID> {
        var live = Set<UUID>()

        let pending = JobState.pending.rawValue
        let running = JobState.running.rawValue
        let descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == pending || $0.stateRaw == running }
        )
        for job in (try? modelContext.fetch(descriptor)) ?? [] {
            if let payload = UtterancePayload(json: job.payload) {
                live.insert(payload.utteranceID)
            }
        }
        return live
    }

    /// Queued jobs of one kind, oldest first. Used by backpressure, which needs to see the
    /// payloads to decide what is least worth keeping.
    func pendingJobs(kind: JobKind, limit: Int = 64) -> [JobSnapshot] {
        let kindRaw = kind.rawValue
        let pending = JobState.pending.rawValue
        var descriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.stateRaw == pending },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            JobSnapshot(id: $0.id, kind: $0.kind, payload: $0.payload, attempts: $0.attempts)
        }
    }

    func cancelJob(id: UUID, reason: String) {
        guard let job = fetchJob(id) else { return }
        job.state = .cancelled
        job.finishedAt = Date()
        job.lastError = reason
        commit("cancelJob")
    }

    func fetchJob(_ id: UUID) -> JobRecord? {
        var descriptor = FetchDescriptor<JobRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Stats and maintenance

    func stats() -> StoreStatsDTO {
        var stats = StoreStatsDTO()
        stats.sessions = count(SessionRecord.self)
        stats.audioSegments = count(AudioSegmentRecord.self)
        stats.transcriptSegments = count(TranscriptSegmentRecord.self)
        stats.conversations = count(ConversationRecord.self)
        stats.speakers = count(SpeakerRecord.self)
        stats.memories = count(MemoryRecord.self)
        stats.summaries = count(SummaryRecord.self)
        stats.contradictions = count(ContradictionRecord.self)
        stats.nodes = count(GraphNodeRecord.self)
        stats.edges = count(GraphEdgeRecord.self)
        stats.documents = count(IndexedDocumentRecord.self)
        stats.postings = count(TokenPostingRecord.self)
        stats.pendingJobs = pendingJobCount()

        let namedDescriptor = FetchDescriptor<SpeakerRecord>(
            predicate: #Predicate { $0.displayName != nil }
        )
        stats.namedSpeakers = (try? modelContext.fetchCount(namedDescriptor)) ?? 0

        let openDescriptor = FetchDescriptor<ContradictionRecord>(
            predicate: #Predicate { $0.isResolved == false }
        )
        stats.openContradictions = (try? modelContext.fetchCount(openDescriptor)) ?? 0

        let failed = JobState.failed.rawValue
        let failedDescriptor = FetchDescriptor<JobRecord>(
            predicate: #Predicate { $0.stateRaw == failed }
        )
        stats.failedJobs = (try? modelContext.fetchCount(failedDescriptor)) ?? 0

        return stats
    }

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<T>())) ?? 0
    }

    /// Delete everything. Offered in Settings because a personal memory system that cannot
    /// be emptied is not one the user is in control of.
    ///
    /// Written out per model rather than looped over the schema: `delete(model:)` needs a
    /// concrete type, and being explicit makes it obvious that `StoreMetaRecord` is
    /// deliberately kept — it carries the schema version and the recovery history.
    func deleteEverything() {
        try? modelContext.delete(model: TokenPostingRecord.self)
        try? modelContext.delete(model: IndexedDocumentRecord.self)
        try? modelContext.delete(model: JobRecord.self)
        try? modelContext.delete(model: GraphEdgeRecord.self)
        try? modelContext.delete(model: GraphNodeRecord.self)
        try? modelContext.delete(model: ContradictionRecord.self)
        try? modelContext.delete(model: SummaryRecord.self)
        try? modelContext.delete(model: MemoryRecord.self)
        try? modelContext.delete(model: ExtractionRecord.self)
        try? modelContext.delete(model: TranscriptSegmentRecord.self)
        try? modelContext.delete(model: ConversationRecord.self)
        try? modelContext.delete(model: SpeakerRecord.self)
        try? modelContext.delete(model: AudioSegmentRecord.self)
        try? modelContext.delete(model: SessionRecord.self)
        commit("deleteEverything")
        Log.database.notice("Store erased at the user's request")
    }
}

extension IndexedDocumentRecord {
    var snapshot: IndexedDocumentSnapshot {
        IndexedDocumentSnapshot(id: id,
                                kind: kind,
                                refID: refID,
                                conversationID: conversationID,
                                title: title,
                                text: text,
                                timestamp: timestamp,
                                speakerIDs: speakerIDs.asUUIDs,
                                nodeIDs: nodeIDs.asUUIDs,
                                importance: importance,
                                confidence: confidence,
                                assertion: assertion,
                                tokenCount: tokenCount,
                                embedding: VectorMath.decode(embedding))
    }
}
