import Foundation

/// The seam between the recorder and everything that thinks about what it heard.
///
/// The recorder calls into this from its own serial queues, synchronously, and must never
/// be made to wait — a blocked control queue is a missed segment boundary. So every entry
/// point does nothing but hand work to the actor and return.
final class PipelineCoordinator: RecorderPipeline {
    static let shared = PipelineCoordinator()

    let status: PipelineStatus
    private let worker: PipelineWorker

    private init(store: ClipperStore = .shared,
                 library: AudioLibrary = .shared,
                 settings: AppSettings = .shared) {
        let status = PipelineStatus()
        self.status = status
        self.worker = PipelineWorker(store: store,
                                     library: library,
                                     settings: settings,
                                     status: status)
    }

    /// Exposed so Diagnostics can trigger a full reindex.
    func reindexEverything() {
        Task.detached(priority: .utility) { [worker] in
            await worker.requestReindex()
        }
    }

    /// Crash recovery and the first drain. Called once, before the first frame.
    func bootstrap() {
        Task.detached(priority: .utility) { [worker] in
            await worker.bootstrap()
        }
    }

    /// Foregrounding: pick up anything that was queued while we were suspended.
    func resumeIfNeeded() {
        Task.detached(priority: .utility) { [worker] in
            await worker.drain()
        }
    }

    func requestNamingPromptRefresh() {
        Task.detached(priority: .utility) { [worker] in
            await worker.refreshNamingPrompts()
        }
    }

    /// Ask for a rollup now — used by the "regenerate" action in Diagnostics.
    func regenerateSummaries(forDay date: Date) {
        Task.detached(priority: .utility) { [worker] in
            await worker.enqueueRollups(for: date, force: true)
        }
    }

    // MARK: - RecorderPipeline

    func recorderDidStartSession(id: UUID, at date: Date) {
        let inputName = AudioSessionManager.shared.currentInputName
        let builtIn = AudioSessionManager.shared.isUsingBuiltInMic
        let others = AudioSessionManager.shared.otherAudioPlaying
        Task.detached(priority: .utility) { [worker] in
            await worker.sessionStarted(id: id,
                                        at: date,
                                        inputName: inputName,
                                        usedBuiltInMic: builtIn,
                                        otherAudioPlaying: others)
        }
    }

    func recorderDidEndSession(id: UUID, at date: Date) {
        Task.detached(priority: .utility) { [worker] in
            await worker.sessionEnded(id: id, at: date)
        }
    }

    func recorderDidProduceUtterance(_ utterance: PendingUtterance) {
        Task.detached(priority: .utility) { [worker] in
            await worker.accept(utterance)
        }
    }

    func recorderDidFinishClip(_ clip: Clip, sessionID: UUID) {
        Task.detached(priority: .utility) { [worker] in
            await worker.clipFinished(clip, sessionID: sessionID)
        }
    }
}

/// The single consumer. Everything that reads audio, runs a model or writes to the database
/// happens here, one item at a time.
///
/// ## Backpressure
/// The queue is bounded at `maximumQueueDepth`. When it is full, the **lowest-quality**
/// pending utterance is dropped rather than the newest or the oldest: quality is already
/// measured (SNR and speech ratio), so the thing sacrificed is the thing least likely to
/// have carried a sentence. Every drop is counted and shown in Diagnostics, because
/// silently losing audio is the worst failure this app could have.
///
/// ## Resumability
/// Work lives in `JobRecord` rows, not in memory. Being killed mid-transcription loses at
/// most the current item's progress; the job goes back to `pending` on the next launch and
/// the attempt counter stops anything from retrying forever.
actor PipelineWorker {
    private let store: ClipperStore
    private let library: AudioLibrary
    private let settings: AppSettings
    private let status: PipelineStatus

    private let transcriber: Transcribing = OnDeviceSpeechTranscriber()
    private let classifier = SoundClassifier()
    private let enhancer = SpeechEnhancer()
    private let extractor = ContentExtractor()
    private let builder = MemoryBuilder()
    private let spotlight = SpotlightIndexer.shared

    private var drainTask: Task<Void, Never>?
    private var didBootstrap = false
    private var speechAuthorized: Bool?

    /// Keywords from the previous utterance, for topic-shift detection.
    private var recentKeywords: [String] = []
    private var activeSessionID: UUID?

    private let maximumQueueDepth = 32

    init(store: ClipperStore,
         library: AudioLibrary,
         settings: AppSettings,
         status: PipelineStatus) {
        self.store = store
        self.library = library
        self.settings = settings
        self.status = status
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        library.bootstrap()

        let stranded = await store.resetStrandedJobs()
        let sessions = await store.closeStrandedSessions()
        if stranded > 0 || sessions > 0 {
            Log.pipeline.notice("Recovered \(stranded) jobs and \(sessions) sessions from a previous run")
        }

        // Conversations left open by a crash will never receive another segment.
        let closed = await store.closeInactiveConversations(inactiveFor: 0)
        for id in closed {
            await store.enqueueJob(kind: .closeConversation,
                                   payload: ConversationPayload(conversationID: id).json,
                                   priority: 5)
        }

        let live = await store.liveUtteranceIDs()
        library.purgeOrphanUtterances(keeping: live)
        await store.enqueueJob(kind: .retentionSweep, payload: "{}", priority: -10)

        await refreshNamingPrompts()
        await drain()
    }

    /// Start the consumer if it is not already running.
    func drain() async {
        if let drainTask, !drainTask.isCancelled { return }
        drainTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        drainTask?.cancel()
        drainTask = nil
    }

    private func runLoop() async {
        defer {
            drainTask = nil
            status.set(processing: false, stage: nil)
        }

        while !Task.isCancelled {
            guard let job = await store.claimNextJob() else { break }

            status.set(pending: await store.pendingJobCount())
            status.set(processing: true, stage: Self.stageLabel(for: job.kind))

            do {
                try await perform(job)
                await store.finishJob(id: job.id)
            } catch is CancellationError {
                // Put it back rather than counting an attempt against it.
                await store.failJob(id: job.id, error: "Cancelled")
                return
            } catch {
                Log.pipeline.error("Job \(job.kind.rawValue, privacy: .public) failed: \(error.localizedDescription)")
                await store.failJob(id: job.id, error: error.localizedDescription)
                status.noteFailure(error.localizedDescription)
            }

            status.set(pending: await store.pendingJobCount())
        }
    }

    private static func stageLabel(for kind: JobKind) -> String {
        switch kind {
        case .processUtterance: return "Transcribing"
        case .closeConversation: return "Summarising"
        case .rollupDay: return "Daily summary"
        case .rollupWeek: return "Weekly summary"
        case .rollupTopic: return "Topic summary"
        case .reindexDocument: return "Reindexing"
        case .retentionSweep: return "Tidying up"
        }
    }

    private func perform(_ job: JobSnapshot) async throws {
        switch job.kind {
        case .processUtterance:
            guard let payload = UtterancePayload(json: job.payload) else { return }
            try await processUtterance(payload)
        case .closeConversation:
            guard let payload = ConversationPayload(json: job.payload) else { return }
            try await closeConversation(payload.conversationID)
        case .rollupDay:
            guard let payload = RollupPayload(json: job.payload) else { return }
            await rollupDay(key: payload.key)
        case .rollupWeek:
            guard let payload = RollupPayload(json: job.payload) else { return }
            await rollupWeek(key: payload.key)
        case .rollupTopic:
            guard let payload = RollupPayload(json: job.payload), let nodeID = payload.nodeID else { return }
            await rollupTopic(nodeID: nodeID)
        case .reindexDocument:
            await reindexAll()
        case .retentionSweep:
            await retentionSweep()
        }
    }

    // MARK: - Recorder events

    func sessionStarted(id: UUID, at date: Date, inputName: String?, usedBuiltInMic: Bool, otherAudioPlaying: Bool) async {
        activeSessionID = id
        recentKeywords = []
        await store.startSession(id: id,
                                 at: date,
                                 inputName: inputName,
                                 usedBuiltInMic: usedBuiltInMic,
                                 otherAudioPlaying: otherAudioPlaying)
    }

    func sessionEnded(id: UUID, at date: Date) async {
        await store.endSession(id: id, at: date)
        activeSessionID = nil
        recentKeywords = []

        // Close and summarise whatever was still open. A conversation only gets a summary
        // once it is closed, so stopping must not leave the last one orphaned.
        let closed = await store.closeConversations(sessionID: id, at: date)
        for conversationID in closed {
            await store.enqueueJob(kind: .closeConversation,
                                   payload: ConversationPayload(conversationID: conversationID).json,
                                   priority: 5)
        }
        await enqueueRollups(for: date, force: false)
        await store.enqueueJob(kind: .retentionSweep, payload: "{}", priority: -10)
        await drain()
    }

    func accept(_ utterance: PendingUtterance) async {
        await applyBackpressure()
        let payload = UtterancePayload(utterance: utterance)
        // Live utterances outrank every kind of rollup.
        await store.enqueueJob(kind: .processUtterance, payload: payload.json, priority: 10)
        status.set(pending: await store.pendingJobCount())
        await drain()
    }

    func clipFinished(_ clip: Clip, sessionID: UUID) async {
        await store.recordRollingClip(sessionID: sessionID,
                                      filename: clip.url.lastPathComponent,
                                      startedAt: clip.startDate,
                                      duration: clip.duration,
                                      byteSize: clip.byteSize,
                                      sampleRate: 0)
    }

    /// Drop the least valuable queued utterance when the queue is over depth.
    private func applyBackpressure() async {
        let pending = await store.pendingJobs(kind: .processUtterance, limit: maximumQueueDepth + 8)
        guard pending.count >= maximumQueueDepth else { return }

        struct Scored {
            let job: JobSnapshot
            let payload: UtterancePayload
            let quality: Double
        }

        let scored: [Scored] = pending.compactMap { job in
            guard let payload = UtterancePayload(json: job.payload) else { return nil }
            // Quality: how far above the noise floor, and how much of it was really speech.
            let snrScore = min(1, max(0, (payload.meanSNRDB - 3) / 20))
            return Scored(job: job,
                          payload: payload,
                          quality: 0.6 * snrScore + 0.4 * payload.speechRatio)
        }

        guard let worst = scored.min(by: { $0.quality < $1.quality }) else { return }
        await store.cancelJob(id: worst.job.id, reason: "Queue full — lowest-quality item dropped")
        library.discardUtterance(at: library.utterancesDirectory
            .appendingPathComponent(worst.payload.filename, isDirectory: false))
        status.noteDropped()
        Log.pipeline.error("Backpressure dropped an utterance (quality \(String(format: "%.2f", worst.quality)))")
    }

    // MARK: - Stage 1: one utterance

    private func processUtterance(_ payload: UtterancePayload) async throws {
        let config = settings.config
        let url = library.utterancesDirectory.appendingPathComponent(payload.filename, isDirectory: false)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // The audio is gone: a crash between enqueue and processing, or a retention
            // sweep. Nothing to retry.
            Log.pipeline.notice("Utterance audio missing; skipping")
            return
        }
        guard let (samples, sampleRate) = SpeechEnhancer.readMono(url: url), !samples.isEmpty else {
            library.discardUtterance(at: url)
            throw PipelineError.unreadableAudio
        }

        // The raw-layer row goes in first, so the fact that something was heard survives
        // whatever happens to the rest of the pipeline.
        await store.createEvidenceSegment(id: payload.utteranceID,
                                          sessionID: payload.sessionID,
                                          filename: library.evidenceURL(for: payload.utteranceID).lastPathComponent,
                                          startedAt: payload.startedAt,
                                          endedAt: payload.endedAt,
                                          sampleRate: payload.sampleRate,
                                          byteSize: 0,
                                          meanSNRDB: payload.meanSNRDB,
                                          peakLevelDB: payload.peakLevelDB,
                                          noiseFloorDB: payload.noiseFloorDB,
                                          speechRatio: payload.speechRatio)

        // Stage: is this actually speech?
        let profile = await Log.intervalAsync("pipeline.classify") {
            await classifier.classify(url: url)
        }
        await store.updateSegment(id: payload.utteranceID, profile: profile)

        let speechScore = profile.available ? profile.speechScore : payload.speechRatio
        let floor = config.sensitivity.minSpeechConfidence

        guard config.transcriptionEnabled else {
            try await retainOrDiscard(payload: payload, source: url, config: config, state: .skipped)
            status.noteSkipped()
            return
        }
        guard speechScore >= floor else {
            Log.pipeline.debug("Rejected non-speech utterance (score \(String(format: "%.2f", speechScore)), label \(profile.topLabel ?? "none"))")
            // Below the floor: the raw row stays, the audio does not.
            await store.updateSegment(id: payload.utteranceID,
                                      processingState: .skipped,
                                      audioAvailable: false)
            library.discardUtterance(at: url)
            status.noteSkipped()
            return
        }

        guard await ensureSpeechAuthorization() else {
            try await retainOrDiscard(payload: payload, source: url, config: config, state: .failed)
            throw PipelineError.transcription(TranscriptionError.notAuthorized.localizedDescription)
        }

        // Stage: clean up the audio, but only when it needs it.
        var transcriptionURL = url
        var cleanedURL: URL?
        if SpeechEnhancer.shouldEnhance(meanSNRDB: payload.meanSNRDB) {
            let enhanced = Log.interval("pipeline.enhance") { enhancer.enhance(samples) }
            let candidate = library.utterancesDirectory
                .appendingPathComponent("\(payload.utteranceID.uuidString)-clean.wav", isDirectory: false)
            if SpeechEnhancer.writeMono(enhanced, sampleRate: sampleRate, to: candidate) {
                transcriptionURL = candidate
                cleanedURL = candidate
            }
        }
        defer { if let cleanedURL { library.discardUtterance(at: cleanedURL) } }

        await store.updateSegment(id: payload.utteranceID, processingState: .transcribing)

        // Stage: transcribe.
        let output: TranscriptionOutput
        do {
            output = try await Log.intervalAsync("pipeline.transcribe") {
                try await transcriber.transcribe(fileAt: transcriptionURL)
            }
        } catch TranscriptionError.emptyResult {
            await store.updateSegment(id: payload.utteranceID,
                                      processingState: .skipped,
                                      audioAvailable: false)
            library.discardUtterance(at: url)
            status.noteSkipped()
            return
        } catch {
            try await retainOrDiscard(payload: payload, source: url, config: config, state: .failed)
            throw PipelineError.transcription(error.localizedDescription)
        }

        // Stage: whose voice was that? Features come from the *original* audio — noise
        // reduction changes timbre, which is precisely what the speaker match depends on.
        var match: SpeakerMatch?
        if config.speakerClusteringEnabled {
            let embedding = Log.interval("pipeline.speakerFeatures") {
                SpeakerFeatures.embedding(from: samples, sampleRate: sampleRate)
            }
            if !embedding.isEmpty {
                match = await store.attributeSpeaker(embedding: embedding, seconds: payload.duration)
            }
        }

        // Stage: keep the audio as evidence, if the user wants that.
        try await retainOrDiscard(payload: payload, source: url, config: config, state: .complete)

        let quality = await store.segmentQuality(id: payload.utteranceID)
        let isLowConfidence = !output.confidenceReported
            || output.confidence < 0.45
            || quality < 0.35
            || (profile.available && profile.musicConfidence > 0.5)
        let assertion: AssertionKind = isLowConfidence ? .uncertain : .stated

        let transcriptID = UUID()
        await store.insertTranscript(id: transcriptID,
                                     sessionID: payload.sessionID,
                                     audioSegmentID: payload.utteranceID,
                                     speakerID: match?.speakerID,
                                     speakerConfidence: match?.confidence ?? 0,
                                     startedAt: payload.startedAt,
                                     endedAt: payload.endedAt,
                                     index: payload.index,
                                     text: output.text,
                                     confidence: output.confidence,
                                     audioQuality: quality,
                                     assertion: assertion,
                                     languageCode: output.localeIdentifier,
                                     wordTimings: output.words,
                                     isLowConfidence: isLowConfidence)

        // Stage: what was in it?
        let extraction = Log.interval("pipeline.extract") {
            extractor.extract(from: output.text, occurredAt: payload.startedAt)
        }

        let topicShift = ContentExtractor.isTopicShift(from: recentKeywords, to: extraction.keywords)
        if !extraction.keywords.isEmpty { recentKeywords = extraction.keywords }

        let assignment = await store.assignConversation(segmentID: transcriptID,
                                                        sessionID: payload.sessionID,
                                                        startedAt: payload.startedAt,
                                                        endedAt: payload.endedAt,
                                                        speakerID: match?.speakerID,
                                                        confidence: output.confidence,
                                                        topicShift: topicShift)

        // Stage: brain map.
        let nodeIDs = await buildNodes(extraction: extraction,
                                       match: match,
                                       transcriptID: transcriptID,
                                       occurredAt: payload.startedAt)
        if !nodeIDs.isEmpty {
            await store.attachNodes(conversationID: assignment.conversationID, nodeIDs: nodeIDs)
        }

        await store.insertExtractions(extraction.extractions,
                                      transcriptSegmentID: transcriptID,
                                      conversationID: assignment.conversationID,
                                      speakerID: match?.speakerID,
                                      occurredAt: payload.startedAt)

        // Stage: make it findable.
        let embedding = await Embedder.shared.vector(for: output.text)
        var speakerLabel = "Unknown voice"
        if let speakerID = match?.speakerID, let speaker = await store.speaker(id: speakerID) {
            speakerLabel = speaker.label
        }
        await store.indexDocument(IndexCandidate(kind: .transcriptSegment,
                                                 refID: transcriptID,
                                                 conversationID: assignment.conversationID,
                                                 title: speakerLabel,
                                                 text: output.text,
                                                 timestamp: payload.startedAt,
                                                 speakerIDs: match.map { [$0.speakerID] } ?? [],
                                                 nodeIDs: nodeIDs,
                                                 importance: isLowConfidence ? 0.15 : 0.3,
                                                 confidence: output.confidence,
                                                 assertion: assertion,
                                                 embedding: embedding))

        await store.setTranscriptState(id: transcriptID, state: .complete)
        await store.noteUtterance(sessionID: payload.sessionID, seconds: payload.duration)
        library.discardUtterance(at: url)

        // Any conversation that closed because this utterance started a new one.
        for conversationID in assignment.closed {
            await store.enqueueJob(kind: .closeConversation,
                                   payload: ConversationPayload(conversationID: conversationID).json,
                                   priority: 5)
        }

        status.noteProcessed()
        await refreshNamingPrompts()
    }

    /// Re-encode the utterance into `Evidence/`, or delete it, and set the row's state.
    private func retainOrDiscard(payload: UtterancePayload,
                                 source: URL,
                                 config: ClipperConfig,
                                 state: ProcessingState) async throws {
        guard config.keepEvidenceAudio else {
            await store.updateSegment(id: payload.utteranceID,
                                      processingState: state,
                                      audioAvailable: false)
            return
        }

        guard let retained = library.retainEvidence(utteranceAt: source,
                                                    id: payload.utteranceID,
                                                    quality: config.quality) else {
            await store.updateSegment(id: payload.utteranceID,
                                      processingState: state,
                                      audioAvailable: false)
            return
        }

        let size = Int64((try? retained.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        await store.updateSegment(id: payload.utteranceID,
                                  processingState: state,
                                  byteSize: size,
                                  audioAvailable: true)
    }

    private func buildNodes(extraction: ExtractionResult,
                            match: SpeakerMatch?,
                            transcriptID: UUID,
                            occurredAt: Date) async -> [UUID] {
        var nodeIDs: [UUID] = []

        for entity in extraction.entities.prefix(6) {
            if let id = await store.upsertNode(kind: entity.kind,
                                               name: entity.name,
                                               mentionedAt: occurredAt) {
                nodeIDs.append(id)
            }
        }
        for keyword in extraction.keywords.prefix(4) {
            if let id = await store.upsertNode(kind: .topic,
                                               name: keyword,
                                               mentionedAt: occurredAt) {
                nodeIDs.append(id)
            }
        }

        // Co-occurrence edges, capped at the three strongest nodes. Linking every pair
        // would be quadratic per utterance and would bury the real relationships in noise.
        let linkable = Array(nodeIDs.prefix(3))
        for i in 0..<linkable.count {
            for j in (i + 1)..<linkable.count {
                await store.upsertEdge(source: linkable[i],
                                       target: linkable[j],
                                       kind: .relatedTo,
                                       confidence: 0.4,
                                       evidenceIDs: [transcriptID])
            }
        }

        // A named speaker becomes a person node and is linked to what they talked about.
        if let match, let speaker = await store.speaker(id: match.speakerID), speaker.isNamed {
            if let personNode = await store.upsertNode(kind: .person,
                                                       name: speaker.label,
                                                       refID: speaker.id,
                                                       refKind: .manual,
                                                       importanceFloor: 0.5,
                                                       mentionedAt: occurredAt) {
                for target in nodeIDs.prefix(4) {
                    await store.upsertEdge(source: personNode,
                                           target: target,
                                           kind: .mentions,
                                           confidence: match.confidence,
                                           evidenceIDs: [transcriptID])
                }
                nodeIDs.append(personNode)
            }
        }

        return nodeIDs
    }

    // MARK: - Stage 2: a conversation closed

    private func closeConversation(_ conversationID: UUID) async throws {
        let config = settings.config
        guard let conversation = await store.conversation(id: conversationID) else { return }
        let lines = await store.transcriptLines(conversationID: conversationID)
        guard !lines.isEmpty else { return }

        let bodyText = lines.map(\.text).joined(separator: " ")
        let keywords = ContentExtractor.keywords(in: bodyText, limit: 8)

        let input = SummarizationInput(lines: lines.map { "\($0.speakerLabel): \($0.text)" },
                                       scope: .conversation,
                                       keywords: keywords,
                                       speakerLabels: Array(Set(lines.map(\.speakerLabel))),
                                       periodStart: conversation.startedAt,
                                       periodEnd: conversation.endedAt)

        var draft: SummaryDraft?
        var summary: SummaryDTO?

        if config.summariesEnabled {
            draft = await SummarizerPool.shared.summarize(input,
                                                          preferLanguageModel: config.preferOnDeviceModel)
            if let draft {
                let embedding = await Embedder.shared.vector(for: draft.text)
                summary = await store.upsertSummary(scope: .conversation,
                                                    key: conversationID.uuidString,
                                                    draft: draft,
                                                    periodStart: conversation.startedAt,
                                                    periodEnd: conversation.endedAt,
                                                    sourceKind: .transcriptSegment,
                                                    sourceIDs: lines.map(\.id),
                                                    embedding: embedding)
                await store.setConversationTitle(id: conversationID,
                                                 title: draft.title,
                                                 summaryID: summary?.id)
                if let summary {
                    await store.indexDocument(IndexCandidate(kind: .summary,
                                                             refID: summary.id,
                                                             conversationID: conversationID,
                                                             title: summary.title,
                                                             text: summary.text,
                                                             timestamp: conversation.startedAt,
                                                             speakerIDs: conversation.speakerIDs,
                                                             nodeIDs: conversation.nodeIDs,
                                                             importance: max(0.4, conversation.importance),
                                                             confidence: summary.confidence,
                                                             assertion: .summarised,
                                                             embedding: embedding))
                }
                status.noteSummary(at: Date())
            }
        }

        // Curated memories.
        let extractions = await store.extractions(conversationID: conversationID)
        let updated = await store.conversation(id: conversationID) ?? conversation
        let candidates = builder.build(extractions: extractions,
                                       conversation: updated,
                                       keywords: keywords,
                                       nodeIDs: updated.nodeIDs,
                                       summary: draft,
                                       summaryID: summary?.id)

        var stored: [MemoryDTO] = []
        for candidate in candidates.prefix(24) {
            var enriched = candidate
            enriched.embedding = await Embedder.shared.vector(
                for: candidate.title + " " + candidate.detail
            )
            if let memory = await store.upsertMemory(enriched) {
                stored.append(memory)
            }
        }

        await detectContradictions(among: stored)
        await link(memories: stored, to: updated)
        await publishToSpotlight(conversation: updated, summary: summary, memories: stored)

        await enqueueRollups(for: conversation.startedAt, force: false)
        for nodeID in updated.nodeIDs.prefix(3) {
            await store.enqueueJob(kind: .rollupTopic,
                                   payload: RollupPayload(key: nodeID.uuidString, nodeID: nodeID).json,
                                   priority: -5)
        }
        status.noteChange()
    }

    /// Look for negation conflicts between the new memories and what is already stored.
    ///
    /// The supersede chain already handles a *changed* statement under the same key; this
    /// catches the other shape — two separately-keyed memories where one negates the other.
    private func detectContradictions(among memories: [MemoryDTO]) async {
        let kinds = Set(memories.map(\.kind))
        for kind in kinds {
            let existing = await store.memories(kinds: [kind], limit: 60)
            let fresh = memories.filter { $0.kind == kind }
            for candidate in fresh {
                for other in existing where other.id != candidate.id {
                    guard MemoryBuilder.contradicts(candidate.title, other.title) else { continue }
                    let earlier = other.createdAt <= candidate.createdAt ? other : candidate
                    let later = earlier.id == other.id ? candidate : other
                    await store.recordContradiction(
                        earlier: earlier.id,
                        later: later.id,
                        explanation: "\"\(earlier.title)\" conflicts with \"\(later.title)\".",
                        confidence: min(earlier.confidence, later.confidence)
                    )
                }
            }
        }
    }

    private func link(memories: [MemoryDTO], to conversation: ConversationDTO) async {
        for memory in memories.prefix(8) {
            guard let memoryNode = await store.upsertNode(kind: .memory,
                                                          name: memory.title,
                                                          refID: memory.id,
                                                          refKind: .memory,
                                                          importanceFloor: memory.importance,
                                                          mentionedAt: memory.lastSeenAt) else { continue }
            for topic in conversation.nodeIDs.prefix(4) {
                await store.upsertEdge(source: memoryNode,
                                       target: topic,
                                       kind: .about,
                                       confidence: memory.confidence,
                                       evidenceIDs: memory.sourceIDs)
            }
            let embedding = await Embedder.shared.vector(for: memory.title + " " + memory.detail)
            await store.indexDocument(IndexCandidate(kind: .memory,
                                                     refID: memory.id,
                                                     conversationID: conversation.id,
                                                     title: memory.title,
                                                     text: memory.detail.isEmpty ? memory.title : memory.detail,
                                                     timestamp: memory.lastSeenAt,
                                                     speakerIDs: memory.subjectSpeakerID.map { [$0] } ?? [],
                                                     nodeIDs: memory.nodeIDs,
                                                     importance: memory.importance,
                                                     confidence: memory.confidence,
                                                     assertion: memory.assertion,
                                                     embedding: embedding))
        }
    }

    private func publishToSpotlight(conversation: ConversationDTO,
                                    summary: SummaryDTO?,
                                    memories: [MemoryDTO]) async {
        guard settings.config.spotlightEnabled else { return }
        var items = [SpotlightIndexer.item(for: conversation, summary: summary)]
        if let summary { items.append(SpotlightIndexer.item(for: summary)) }
        for memory in memories.prefix(6) {
            items.append(SpotlightIndexer.item(for: memory, topics: conversation.topicNames))
        }
        await spotlight.publish(items)
    }

    // MARK: - Stage 3: rollups

    func enqueueRollups(for date: Date, force: Bool) async {
        let dayKey = SummaryKey.day(date)
        let weekKey = SummaryKey.week(date)
        if force {
            await store.cancelJobs(kind: .rollupDay)
            await store.cancelJobs(kind: .rollupWeek)
        }
        await store.enqueueJob(kind: .rollupDay,
                               payload: RollupPayload(key: dayKey).json,
                               priority: -3)
        await store.enqueueJob(kind: .rollupWeek,
                               payload: RollupPayload(key: weekKey).json,
                               priority: -4)
        await drain()
    }

    private func rollupDay(key: String) async {
        guard settings.config.summariesEnabled,
              let bounds = SummaryKey.bounds(forDayKey: key) else { return }

        let conversations = await store.conversations(from: bounds.start, to: bounds.end, limit: 80)
        let described = conversations.filter { $0.summaryText?.isEmpty == false }
        guard !described.isEmpty else { return }

        // Summarising the summaries, not the transcript: incremental by construction, and
        // it keeps the prompt small however long the day was.
        let lines = described.map { conversation -> String in
            let time = conversation.startedAt.formatted(date: .omitted, time: .shortened)
            return "\(time) — \(conversation.title): \(conversation.summaryText ?? "")"
        }
        let keywords = ContentExtractor.keywords(in: lines.joined(separator: " "), limit: 8)
        let input = SummarizationInput(lines: lines,
                                       scope: .day,
                                       keywords: keywords,
                                       speakerLabels: Array(Set(described.flatMap(\.speakerLabels))),
                                       periodStart: bounds.start,
                                       periodEnd: bounds.end)

        guard var draft = await SummarizerPool.shared.summarize(
            input, preferLanguageModel: settings.config.preferOnDeviceModel
        ) else { return }

        draft.title = bounds.start.formatted(date: .abbreviated, time: .omitted) + " — " + draft.title

        let summary = await store.upsertSummary(scope: .day,
                                                key: key,
                                                draft: draft,
                                                periodStart: bounds.start,
                                                periodEnd: bounds.end,
                                                sourceKind: .conversation,
                                                sourceIDs: described.map(\.id),
                                                embedding: await Embedder.shared.vector(for: draft.text))
        await indexSummary(summary)
        status.noteSummary(at: Date())
    }

    private func rollupWeek(key: String) async {
        guard settings.config.summariesEnabled,
              let bounds = SummaryKey.bounds(forWeekKey: key) else { return }

        let days = await store.summaries(scope: .day, limit: 60)
            .filter { $0.periodStart >= bounds.start && $0.periodStart < bounds.end }
        guard days.count >= 2 else { return }

        let lines = days.map { "\($0.title): \($0.text)" }
        let input = SummarizationInput(lines: lines,
                                       scope: .week,
                                       keywords: ContentExtractor.keywords(in: lines.joined(separator: " "), limit: 8),
                                       speakerLabels: [],
                                       periodStart: bounds.start,
                                       periodEnd: bounds.end)

        guard var draft = await SummarizerPool.shared.summarize(
            input, preferLanguageModel: settings.config.preferOnDeviceModel
        ) else { return }
        draft.title = "Week of " + bounds.start.formatted(date: .abbreviated, time: .omitted)

        let summary = await store.upsertSummary(scope: .week,
                                                key: key,
                                                draft: draft,
                                                periodStart: bounds.start,
                                                periodEnd: bounds.end,
                                                sourceKind: .summary,
                                                sourceIDs: days.map(\.id),
                                                embedding: await Embedder.shared.vector(for: draft.text))
        await indexSummary(summary)
    }

    private func rollupTopic(nodeID: UUID) async {
        guard settings.config.summariesEnabled, let node = await store.node(id: nodeID) else { return }
        // Not worth a summary until a topic has actually recurred.
        guard node.mentionCount >= 4 else { return }

        let memories = await store.memories(limit: 200)
            .filter { $0.nodeIDs.contains(nodeID) }
        guard memories.count >= 2 else { return }

        let lines = memories.prefix(24).map { "\($0.kind.title): \($0.title)" }
        let input = SummarizationInput(lines: Array(lines),
                                       scope: node.kind == .project ? .project : .topic,
                                       keywords: [node.name],
                                       speakerLabels: [],
                                       periodStart: memories.map(\.firstSeenAt).min() ?? Date(),
                                       periodEnd: memories.map(\.lastSeenAt).max() ?? Date())

        guard var draft = await SummarizerPool.shared.summarize(
            input, preferLanguageModel: settings.config.preferOnDeviceModel
        ) else { return }
        draft.title = node.name

        let summary = await store.upsertSummary(scope: input.scope,
                                                key: nodeID.uuidString,
                                                draft: draft,
                                                periodStart: input.periodStart,
                                                periodEnd: input.periodEnd,
                                                sourceKind: .memory,
                                                sourceIDs: memories.map(\.id),
                                                embedding: await Embedder.shared.vector(for: draft.text))
        await store.setNodeSummary(nodeID: nodeID, summaryID: summary.id)
        await indexSummary(summary)
        if settings.config.spotlightEnabled {
            await spotlight.publish([SpotlightIndexer.item(for: node)])
        }
    }

    private func indexSummary(_ summary: SummaryDTO) async {
        await store.indexDocument(IndexCandidate(kind: .summary,
                                                 refID: summary.id,
                                                 conversationID: nil,
                                                 title: summary.title,
                                                 text: summary.text,
                                                 timestamp: summary.periodStart,
                                                 speakerIDs: [],
                                                 nodeIDs: [],
                                                 importance: 0.5,
                                                 confidence: summary.confidence,
                                                 assertion: .summarised,
                                                 embedding: []))
        if settings.config.spotlightEnabled {
            await spotlight.publish([SpotlightIndexer.item(for: summary)])
        }
    }

    // MARK: - Maintenance

    private func retentionSweep() async {
        let config = settings.config

        let expired = library.sweepEvidence(retention: config.retention)
        if !expired.isEmpty { await store.markEvidenceExpired(ids: expired) }

        let live = await store.liveUtteranceIDs()
        library.purgeOrphanUtterances(keeping: live)

        await store.reconcileRollingClips(existing: library.rollingFilenames())
        await store.pruneFinishedJobs()

        if !config.spotlightEnabled {
            await spotlight.removeAll()
        }
        status.noteChange()
    }

    private func reindexAll() async {
        let documents = await store.documentsNeedingReindex(limit: 400)
        for document in documents {
            let embedding = await Embedder.shared.vector(for: document.text)
            await store.indexDocument(IndexCandidate(kind: document.kind,
                                                     refID: document.refID,
                                                     conversationID: document.conversationID,
                                                     title: document.title,
                                                     text: document.text,
                                                     timestamp: document.timestamp,
                                                     speakerIDs: document.speakerIDs,
                                                     nodeIDs: document.nodeIDs,
                                                     importance: document.importance,
                                                     confidence: document.confidence,
                                                     assertion: document.assertion,
                                                     embedding: embedding))
            if Task.isCancelled { return }
        }
        Log.index.notice("Reindexed \(documents.count) documents")
        status.noteChange()
    }

    func requestReindex() async {
        await store.enqueueJob(kind: .reindexDocument, payload: "{}", priority: -20)
        await drain()
    }

    func refreshNamingPrompts() async {
        guard settings.config.speakerNamingPrompts else {
            status.set(speakersAwaitingNames: [])
            return
        }
        status.set(speakersAwaitingNames: await store.speakersAwaitingNames())
    }

    private func ensureSpeechAuthorization() async -> Bool {
        if let speechAuthorized { return speechAuthorized }
        let granted = await transcriber.requestAuthorization()
        speechAuthorized = granted
        if !granted {
            Log.transcription.error("Speech recognition permission denied")
        }
        return granted
    }
}

enum PipelineError: LocalizedError {
    case unreadableAudio
    case transcription(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio: return "That clip's audio could not be read."
        case .transcription(let message): return message
        }
    }
}
