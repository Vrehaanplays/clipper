import Foundation
import SwiftData

/// Every read and every write of the database, on one serial actor.
///
/// ## Why one actor for both
/// SwiftData's `ModelContext` is not thread-safe and its objects are bound to the context
/// that fetched them. Two contexts writing the same store is where the sharp edges are. So
/// there is exactly one context, it lives on this actor, and **nothing leaves the actor
/// except value types** (see `DTOs.swift`).
///
/// Serialising reads behind writes is a deliberate trade. Every operation here is an
/// indexed fetch or a small mutation measured in single-digit milliseconds; the expensive
/// work — FFTs, transcription, model inference — happens outside, and only its *result*
/// comes in. Search latency measurements are in docs/PERFORMANCE.md.
@ModelActor
actor ClipperStore {
    static let shared = ClipperStore(modelContainer: ClipperDatabase.shared.container)

    /// Commit, and report rather than swallow. A failed save is a real problem — the user
    /// will notice missing memories — so it is logged and surfaced in Diagnostics.
    func commit(_ what: StaticString) {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            Log.database.error("Save failed (\(what, privacy: .public)): \(error.localizedDescription)")
            lastSaveError = error.localizedDescription
            modelContext.rollback()
        }
    }

    private(set) var lastSaveError: String?

    func clearSaveError() { lastSaveError = nil }

    // MARK: - Sessions

    func startSession(id: UUID,
                      at date: Date,
                      inputName: String?,
                      usedBuiltInMic: Bool,
                      otherAudioPlaying: Bool) {
        let record = SessionRecord(id: id,
                                   startedAt: date,
                                   inputName: inputName,
                                   usedBuiltInMic: usedBuiltInMic,
                                   otherAudioPlaying: otherAudioPlaying)
        modelContext.insert(record)
        commit("startSession")
    }

    func endSession(id: UUID, at date: Date) {
        guard let record = fetchSession(id) else { return }
        record.endedAt = date
        commit("endSession")
    }

    func noteInterruption(sessionID: UUID) {
        guard let record = fetchSession(sessionID) else { return }
        record.interruptionCount += 1
        commit("noteInterruption")
    }

    func noteUtterance(sessionID: UUID, seconds: Double) {
        guard let record = fetchSession(sessionID) else { return }
        record.utteranceCount += 1
        record.speechSeconds += seconds
        commit("noteUtterance")
    }

    /// Any session left open by a crash. Closed at the recorded end of its last audio so
    /// the duration is not inflated by however long the app was dead.
    func closeStrandedSessions() -> Int {
        let descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt == nil }
        )
        guard let open = try? modelContext.fetch(descriptor), !open.isEmpty else { return 0 }
        for session in open {
            let identifier = session.id
            let segments = FetchDescriptor<AudioSegmentRecord>(
                predicate: #Predicate { $0.sessionID == identifier },
                sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
            )
            let last = (try? modelContext.fetch(segments))?.first
            session.endedAt = last?.endedAt ?? session.startedAt
        }
        commit("closeStrandedSessions")
        Log.database.notice("Closed \(open.count) stranded sessions")
        return open.count
    }

    func sessions(limit: Int = 50, offset: Int = 0) -> [SessionDTO] {
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.dto)
    }

    func sessions(from start: Date, to end: Date, limit: Int = 50) -> [SessionDTO] {
        var descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.dto)
    }

    /// Days that actually have something in them, newest first — used to skip empty days
    /// in the timeline instead of making the user page through them.
    /// Days the timeline has something to show.
    ///
    /// Sessions count as well as conversations: a day when Clipper listened and nobody
    /// said anything is still a day it was running, and the timeline says so rather than
    /// leaving a hole the user has to interpret.
    func daysWithActivity(limit: Int = 60) -> [Date] {
        var conversationDescriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        conversationDescriptor.fetchLimit = limit * 8
        var sessionDescriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        sessionDescriptor.fetchLimit = limit * 8

        let calendar = Calendar.current
        var starts = ((try? modelContext.fetch(conversationDescriptor)) ?? []).map(\.startedAt)
        starts += ((try? modelContext.fetch(sessionDescriptor)) ?? []).map(\.startedAt)

        var seen: Set<Date> = []
        var days: [Date] = []
        for start in starts.sorted(by: >) {
            let day = calendar.startOfDay(for: start)
            guard seen.insert(day).inserted else { continue }
            days.append(day)
            if days.count >= limit { break }
        }
        return days
    }

    func fetchSession(_ id: UUID) -> SessionRecord? {
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Audio segments

    /// Mirror a finished rolling clip into the raw layer. The rolling buffer itself is
    /// still the filesystem's business; this row exists so the timeline can show that
    /// Clipper was listening even where nobody spoke.
    func recordRollingClip(sessionID: UUID,
                           filename: String,
                           startedAt: Date,
                           duration: TimeInterval,
                           byteSize: Int64,
                           sampleRate: Double) {
        let record = AudioSegmentRecord(sessionID: sessionID,
                                        kind: .rolling,
                                        filename: filename,
                                        startedAt: startedAt,
                                        endedAt: startedAt.addingTimeInterval(duration),
                                        sampleRate: sampleRate,
                                        byteSize: byteSize,
                                        processingState: .complete)
        modelContext.insert(record)
        commit("recordRollingClip")
    }

    /// Drop rolling rows whose file the buffer has already deleted, so the raw layer does
    /// not slowly fill with references to nothing.
    func reconcileRollingClips(existing filenames: Set<String>) {
        let rolling = AudioSegmentKind.rolling.rawValue
        let descriptor = FetchDescriptor<AudioSegmentRecord>(
            predicate: #Predicate { $0.kindRaw == rolling }
        )
        guard let records = try? modelContext.fetch(descriptor) else { return }
        var removed = 0
        for record in records where !filenames.contains(record.filename) {
            modelContext.delete(record)
            removed += 1
        }
        if removed > 0 {
            commit("reconcileRollingClips")
            Log.database.debug("Reconciled \(removed) rolling clip rows")
        }
    }

    /// The raw-layer row for one retained utterance.
    func createEvidenceSegment(id: UUID,
                               sessionID: UUID,
                               filename: String,
                               startedAt: Date,
                               endedAt: Date,
                               sampleRate: Double,
                               byteSize: Int64,
                               meanSNRDB: Double,
                               peakLevelDB: Double,
                               noiseFloorDB: Double,
                               speechRatio: Double) {
        let record = AudioSegmentRecord(id: id,
                                        sessionID: sessionID,
                                        kind: .evidence,
                                        filename: filename,
                                        startedAt: startedAt,
                                        endedAt: endedAt,
                                        sampleRate: sampleRate,
                                        byteSize: byteSize,
                                        meanSNRDB: meanSNRDB,
                                        peakLevelDB: peakLevelDB,
                                        noiseFloorDB: noiseFloorDB,
                                        speechRatio: speechRatio,
                                        processingState: .classifying)
        modelContext.insert(record)
        commit("createEvidenceSegment")
    }

    func updateSegment(id: UUID,
                       profile: SoundProfile? = nil,
                       processingState: ProcessingState? = nil,
                       byteSize: Int64? = nil,
                       audioAvailable: Bool? = nil) {
        guard let record = fetchSegment(id) else { return }
        if let profile {
            record.speechConfidence = profile.speechConfidence
            record.musicConfidence = profile.musicConfidence
            record.classifierLabel = profile.topLabel
        }
        if let processingState { record.processingState = processingState }
        if let byteSize { record.byteSize = byteSize }
        if let audioAvailable { record.audioAvailable = audioAvailable }
        commit("updateSegment")
    }

    /// Retention removed the audio. The row stays so the transcript can say the audio has
    /// expired, which is the honest thing rather than a broken play button.
    func markEvidenceExpired(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let record = fetchSegment(id) else { continue }
            record.audioAvailable = false
            record.byteSize = 0
        }
        commit("markEvidenceExpired")
    }

    func segmentQuality(id: UUID) -> Double {
        fetchSegment(id)?.qualityScore ?? 0
    }

    func evidenceAudioAvailable(id: UUID) -> Bool {
        fetchSegment(id)?.audioAvailable ?? false
    }

    func fetchSegment(_ id: UUID) -> AudioSegmentRecord? {
        var descriptor = FetchDescriptor<AudioSegmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Speakers

    /// Match a voice feature vector against the known clusters, or start a new one.
    ///
    /// Nearest-centroid with a cosine threshold. This is not diarization and does not
    /// pretend to be: the returned `confidence` is the margin by which the match beat the
    /// threshold, and anything weak is stored as such and rendered as uncertain.
    func attributeSpeaker(embedding: [Float],
                          seconds: Double,
                          threshold: Double = 0.82) -> SpeakerMatch? {
        guard !embedding.isEmpty else { return nil }
        let normalised = VectorMath.normalized(embedding)

        let speakers = (try? modelContext.fetch(FetchDescriptor<SpeakerRecord>())) ?? []

        var best: SpeakerRecord?
        var bestScore = -1.0
        for speaker in speakers {
            let centroid = VectorMath.decode(speaker.embedding)
            guard !centroid.isEmpty else { continue }
            let score = VectorMath.cosine(normalised, centroid)
            if score > bestScore {
                bestScore = score
                best = speaker
            }
        }

        if let best, bestScore >= threshold {
            best.embedding = VectorMath.encode(
                VectorMath.runningMean(current: VectorMath.decode(best.embedding),
                                       count: best.sampleCount,
                                       adding: normalised)
            )
            best.sampleCount += 1
            best.totalSpeechSeconds += seconds
            best.updatedAt = Date()
            commit("attributeSpeaker")
            // Map the cosine score onto 0...1 across the band above the threshold, so a
            // bare pass reads as low confidence rather than as certainty.
            let margin = (bestScore - threshold) / max(0.0001, 1 - threshold)
            return SpeakerMatch(speakerID: best.id,
                                confidence: min(1, 0.4 + 0.6 * margin),
                                isNewCluster: false,
                                sampleCount: best.sampleCount)
        }

        // No cluster was close enough. A new voice, with low confidence by construction.
        let colorIndex = speakers.count % 8
        let speaker = SpeakerRecord(embedding: VectorMath.encode(normalised),
                                    sampleCount: 1,
                                    totalSpeechSeconds: seconds,
                                    promptState: .pending,
                                    colorIndex: colorIndex)
        modelContext.insert(speaker)
        commit("createSpeaker")
        return SpeakerMatch(speakerID: speaker.id,
                            confidence: 0.3,
                            isNewCluster: true,
                            sampleCount: 1)
    }

    func speakers() -> [SpeakerDTO] {
        let descriptor = FetchDescriptor<SpeakerRecord>(
            sortBy: [SortDescriptor(\.totalSpeechSeconds, order: .reverse)]
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.dto)
    }

    func speaker(id: UUID) -> SpeakerDTO? {
        fetchSpeaker(id)?.dto
    }

    /// Voices worth asking the user to name: enough audio to be a real person, not already
    /// named, and not skipped.
    func speakersAwaitingNames(minimumSeconds: Double = 12, minimumSamples: Int = 3) -> [SpeakerDTO] {
        let skipped = SpeakerPromptState.skipped.rawValue
        let named = SpeakerPromptState.named.rawValue
        let descriptor = FetchDescriptor<SpeakerRecord>(
            predicate: #Predicate {
                $0.displayName == nil && $0.promptStateRaw != skipped && $0.promptStateRaw != named
            },
            sortBy: [SortDescriptor(\.totalSpeechSeconds, order: .reverse)]
        )
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        return candidates
            .filter { speaker in
                guard speaker.totalSpeechSeconds >= minimumSeconds else { return false }
                // "Ask later" means exactly that: the voice comes back only once there is
                // substantially more evidence, so the prompt cannot nag.
                let bar = speaker.promptState == .askLater ? minimumSamples * 3 : minimumSamples
                return speaker.sampleCount >= bar
            }
            .map(\.dto)
    }

    /// Recent lines attributed to one voice — the samples the naming sheet plays back, and
    /// the "what this person said" list.
    func recentLines(speakerID: UUID, limit: Int = 20) -> [TranscriptLineDTO] {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.speakerID == speakerID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map { decorate($0) }
    }

    func renameSpeaker(id: UUID, to name: String) {
        guard let speaker = fetchSpeaker(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The old label is kept rather than overwritten — history is never destroyed.
        if let existing = speaker.displayName, !existing.isEmpty, existing != trimmed {
            speaker.previousNames.append(existing)
        }
        speaker.displayName = trimmed.isEmpty ? nil : trimmed
        speaker.promptState = trimmed.isEmpty ? .pending : .named
        speaker.updatedAt = Date()
        commit("renameSpeaker")
    }

    func setSpeakerPromptState(id: UUID, state: SpeakerPromptState) {
        guard let speaker = fetchSpeaker(id) else { return }
        speaker.promptState = state
        speaker.updatedAt = Date()
        commit("setSpeakerPromptState")
    }

    /// Two clusters turned out to be one voice. Transcripts are repointed, centroids
    /// blended, and the absorbed row deleted.
    func mergeSpeakers(keep: UUID, absorb: UUID) {
        guard keep != absorb,
              let keeper = fetchSpeaker(keep),
              let absorbed = fetchSpeaker(absorb) else { return }

        let descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.speakerID == absorb }
        )
        let segments = (try? modelContext.fetch(descriptor)) ?? []
        for segment in segments { segment.speakerID = keep }

        let keeperVector = VectorMath.decode(keeper.embedding)
        let absorbedVector = VectorMath.decode(absorbed.embedding)
        if !keeperVector.isEmpty, keeperVector.count == absorbedVector.count {
            let total = keeper.sampleCount + absorbed.sampleCount
            var blended = [Float](repeating: 0, count: keeperVector.count)
            for i in 0..<keeperVector.count {
                blended[i] = (keeperVector[i] * Float(keeper.sampleCount)
                              + absorbedVector[i] * Float(absorbed.sampleCount))
                    / Float(max(1, total))
            }
            keeper.embedding = VectorMath.encode(VectorMath.normalized(blended))
        }
        keeper.sampleCount += absorbed.sampleCount
        keeper.totalSpeechSeconds += absorbed.totalSpeechSeconds
        if let name = absorbed.displayName, keeper.displayName == nil {
            keeper.displayName = name
            keeper.promptState = .named
        }
        keeper.updatedAt = Date()

        modelContext.delete(absorbed)
        commit("mergeSpeakers")
        Log.speakers.notice("Merged speaker clusters, \(segments.count) segments repointed")
    }

    /// The user corrected one line's attribution.
    func reassignSpeaker(segmentID: UUID, to speakerID: UUID?) {
        guard let segment = fetchTranscript(segmentID) else { return }
        segment.speakerID = speakerID
        // A human correction is certain; that is the one place confidence is 1.
        segment.speakerConfidence = speakerID == nil ? 0 : 1
        segment.revision += 1
        commit("reassignSpeaker")
    }

    func fetchSpeaker(_ id: UUID) -> SpeakerRecord? {
        var descriptor = FetchDescriptor<SpeakerRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    func speakerLabels(for ids: [UUID]) -> [String] {
        ids.compactMap { fetchSpeaker($0)?.label }
    }

    // MARK: - Transcript segments

    @discardableResult
    func insertTranscript(id: UUID,
                          sessionID: UUID,
                          audioSegmentID: UUID?,
                          speakerID: UUID?,
                          speakerConfidence: Double,
                          startedAt: Date,
                          endedAt: Date,
                          index: Int,
                          text: String,
                          confidence: Double,
                          audioQuality: Double,
                          assertion: AssertionKind,
                          languageCode: String?,
                          wordTimings: [WordTiming],
                          isLowConfidence: Bool) -> UUID {
        let record = TranscriptSegmentRecord(id: id,
                                             sessionID: sessionID,
                                             audioSegmentID: audioSegmentID,
                                             speakerID: speakerID,
                                             startedAt: startedAt,
                                             endedAt: endedAt,
                                             index: index,
                                             text: text,
                                             confidence: confidence,
                                             audioQuality: audioQuality,
                                             speakerConfidence: speakerConfidence,
                                             assertion: assertion,
                                             processingState: .extracting,
                                             languageCode: languageCode,
                                             isLowConfidence: isLowConfidence)
        record.wordTimings = wordTimings
        modelContext.insert(record)
        commit("insertTranscript")
        return record.id
    }

    func setTranscriptState(id: UUID, state: ProcessingState) {
        guard let record = fetchTranscript(id) else { return }
        record.processingState = state
        commit("setTranscriptState")
    }

    /// A user edit. The original is preserved, because a corrected transcript must not
    /// quietly erase what was actually heard.
    func editTranscript(id: UUID, text: String) {
        guard let record = fetchTranscript(id) else { return }
        if record.originalText == nil { record.originalText = record.text }
        record.text = text
        record.revision += 1
        record.assertion = .stated
        commit("editTranscript")
    }

    func transcriptLines(conversationID: UUID, limit: Int = 500, offset: Int = 0) -> [TranscriptLineDTO] {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.index)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map { decorate($0) }
    }

    func transcriptLines(sessionID: UUID, limit: Int = 500) -> [TranscriptLineDTO] {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        descriptor.fetchLimit = limit
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map { decorate($0) }
    }

    func transcriptLine(id: UUID) -> TranscriptLineDTO? {
        fetchTranscript(id).map { decorate($0) }
    }

    func transcriptLines(ids: [UUID]) -> [TranscriptLineDTO] {
        ids.compactMap { fetchTranscript($0) }.map { decorate($0) }
    }

    /// Everything said in a date range, newest first — the timeline query.
    func transcriptLines(from start: Date, to end: Date, limit: Int = 200, offset: Int = 0) -> [TranscriptLineDTO] {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.map { decorate($0) }
    }

    /// Segments still waiting for a pipeline stage — the resume point after a relaunch.
    func unfinishedTranscriptIDs(limit: Int = 200) -> [UUID] {
        let complete = ProcessingState.complete.rawValue
        let skipped = ProcessingState.skipped.rawValue
        let failed = ProcessingState.failed.rawValue
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(
            predicate: #Predicate {
                $0.processingStateRaw != complete
                    && $0.processingStateRaw != skipped
                    && $0.processingStateRaw != failed
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.id)
    }

    func decorate(_ record: TranscriptSegmentRecord) -> TranscriptLineDTO {
        var label = "Unknown voice"
        var colorIndex = 0
        if let speakerID = record.speakerID, let speaker = fetchSpeaker(speakerID) {
            label = speaker.label
            colorIndex = speaker.colorIndex
        }
        let available = record.audioSegmentID.map { evidenceAudioAvailable(id: $0) } ?? false
        return record.dto(speakerLabel: label,
                          speakerColorIndex: colorIndex,
                          audioAvailable: available)
    }

    func fetchTranscript(_ id: UUID) -> TranscriptSegmentRecord? {
        var descriptor = FetchDescriptor<TranscriptSegmentRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Conversations

    /// Decide which conversation a new segment belongs to, creating one if needed.
    ///
    /// The rule, in order:
    /// 1. No open conversation in this session → start one.
    /// 2. Gap since the last segment longer than `gapThreshold` → the previous one ended.
    /// 3. `topicShift` true and the conversation is already substantial → a new subject.
    /// 4. Otherwise → append.
    ///
    /// Returns the conversation the segment was filed under, and whether anything closed.
    @discardableResult
    func assignConversation(segmentID: UUID,
                            sessionID: UUID,
                            startedAt: Date,
                            endedAt: Date,
                            speakerID: UUID?,
                            confidence: Double,
                            gapThreshold: TimeInterval = 90,
                            maximumDuration: TimeInterval = 3_600,
                            topicShift: Bool = false) -> (conversationID: UUID, closed: [UUID]) {
        var closed: [UUID] = []

        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.isOpen },
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let open = (try? modelContext.fetch(descriptor))?.first

        var target = open
        if let candidate = open {
            let gap = startedAt.timeIntervalSince(candidate.endedAt)
            let length = endedAt.timeIntervalSince(candidate.startedAt)
            let substantial = candidate.segmentCount >= 4
            if gap > gapThreshold || length > maximumDuration || (topicShift && substantial) {
                candidate.isOpen = false
                candidate.closedAt = Date()
                closed.append(candidate.id)
                target = nil
            }
        }

        let conversation: ConversationRecord
        if let target {
            conversation = target
        } else {
            let fresh = ConversationRecord(sessionID: sessionID,
                                           startedAt: startedAt,
                                           endedAt: endedAt)
            modelContext.insert(fresh)
            conversation = fresh
        }

        conversation.endedAt = max(conversation.endedAt, endedAt)
        conversation.segmentCount += 1
        conversation.speechSeconds += endedAt.timeIntervalSince(startedAt)
        // Running mean of transcription confidence.
        let n = Double(conversation.segmentCount)
        conversation.confidence = ((conversation.confidence * (n - 1)) + confidence) / n
        if let speakerID {
            let key = speakerID.uuidString
            if !conversation.speakerIDs.contains(key) { conversation.speakerIDs.append(key) }
        }
        conversation.importance = Self.importance(for: conversation)

        if let segment = fetchTranscript(segmentID) {
            segment.conversationID = conversation.id
        }

        commit("assignConversation")
        return (conversation.id, closed)
    }

    /// Close conversations that have gone quiet. Called on a cadence and on session end,
    /// because a conversation only gets summarised once it is closed.
    func closeInactiveConversations(asOf now: Date = Date(),
                                    inactiveFor: TimeInterval = 120) -> [UUID] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.isOpen }
        )
        guard let open = try? modelContext.fetch(descriptor) else { return [] }
        var closed: [UUID] = []
        for conversation in open where now.timeIntervalSince(conversation.endedAt) > inactiveFor {
            conversation.isOpen = false
            conversation.closedAt = now
            conversation.importance = Self.importance(for: conversation)
            closed.append(conversation.id)
        }
        if !closed.isEmpty { commit("closeInactiveConversations") }
        return closed
    }

    func closeConversations(sessionID: UUID, at date: Date) -> [UUID] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.isOpen }
        )
        guard let open = try? modelContext.fetch(descriptor), !open.isEmpty else { return [] }
        for conversation in open {
            conversation.isOpen = false
            conversation.closedAt = date
            conversation.importance = Self.importance(for: conversation)
        }
        commit("closeConversations")
        return open.map(\.id)
    }

    func setConversationTitle(id: UUID, title: String, summaryID: UUID?) {
        guard let conversation = fetchConversation(id) else { return }
        conversation.title = title
        if let summaryID { conversation.summaryID = summaryID }
        commit("setConversationTitle")
    }

    func attachNodes(conversationID: UUID, nodeIDs: [UUID]) {
        guard let conversation = fetchConversation(conversationID) else { return }
        for id in nodeIDs.asStrings where !conversation.nodeIDs.contains(id) {
            conversation.nodeIDs.append(id)
        }
        commit("attachNodes")
    }

    func conversation(id: UUID) -> ConversationDTO? {
        guard let record = fetchConversation(id) else { return nil }
        return hydrate(record)
    }

    func conversations(limit: Int = 50, offset: Int = 0) -> [ConversationDTO] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return ((try? modelContext.fetch(descriptor)) ?? []).map { hydrate($0) }
    }

    func conversations(from start: Date, to end: Date, limit: Int = 100) -> [ConversationDTO] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map { hydrate($0) }
    }

    func conversations(ids: [UUID]) -> [ConversationDTO] {
        ids.compactMap { fetchConversation($0) }.map { hydrate($0) }
    }

    /// Conversations a given speaker took part in.
    func conversations(speakerID: UUID, limit: Int = 50) -> [ConversationDTO] {
        let key = speakerID.uuidString
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        // `speakerIDs` is a stored array, which `#Predicate` cannot search, so the filter
        // happens in memory over a bounded page rather than over the whole table.
        descriptor.fetchLimit = limit * 6
        let records = (try? modelContext.fetch(descriptor)) ?? []
        return records.filter { $0.speakerIDs.contains(key) }.prefix(limit).map { hydrate($0) }
    }

    func hydrate(_ record: ConversationRecord) -> ConversationDTO {
        let labels = speakerLabels(for: record.speakerIDs.asUUIDs)
        var summaryText: String?
        if let summaryID = record.summaryID, let summary = fetchSummary(summaryID) {
            summaryText = summary.text
        }
        let topics = record.nodeIDs.asUUIDs.prefix(6).compactMap { fetchNode($0)?.name }
        return record.dto(summaryText: summaryText,
                          speakerLabels: labels,
                          topicNames: Array(topics))
    }

    func fetchConversation(_ id: UUID) -> ConversationRecord? {
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Length, speaker variety and density, clamped to 0...1. Deliberately simple and
    /// inspectable — an opaque importance score would be worse than none.
    static func importance(for conversation: ConversationRecord) -> Double {
        let lengthScore = min(1, conversation.speechSeconds / 300)
        let speakerScore = min(1, Double(conversation.speakerIDs.count) / 3)
        let densityScore = min(1, Double(conversation.segmentCount) / 20)
        return min(1, 0.45 * lengthScore + 0.3 * speakerScore + 0.25 * densityScore)
    }
}
