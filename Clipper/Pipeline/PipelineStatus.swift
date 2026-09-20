import Combine
import Foundation

/// What the pipeline is doing, for the UI and the widget.
///
/// A plain `ObservableObject` mutated only on the main queue, exactly like `AudioRecorder`.
/// The pipeline itself is an actor; this is its one window onto SwiftUI.
final class PipelineStatus: ObservableObject {
    /// Utterances queued or in flight.
    @Published private(set) var pending = 0
    @Published private(set) var isProcessing = false
    /// Human-readable stage of the item currently being worked on.
    @Published private(set) var stage: String?
    /// Last failure, kept visible rather than logged and forgotten.
    @Published private(set) var lastError: String?

    @Published private(set) var processedCount = 0
    /// Utterances the classifier rejected as not-speech, or that were below the confidence
    /// floor. Not an error — the count is here so the user can tell that Clipper is
    /// listening and choosing, rather than broken.
    @Published private(set) var skippedCount = 0
    /// Utterances dropped because the queue was full. Visible in Diagnostics because
    /// silently losing audio would be the worst possible failure mode for this app.
    @Published private(set) var droppedCount = 0
    @Published private(set) var failedCount = 0

    /// Voices with enough audio to be worth naming.
    @Published private(set) var speakersAwaitingNames: [SpeakerDTO] = []
    /// The speaker currently being asked about, if a prompt is on screen.
    @Published var namingPrompt: SpeakerDTO?

    /// Last time a conversation was summarised, so the UI can refresh without polling.
    @Published private(set) var lastSummaryAt: Date?
    /// Bumped whenever anything durable changed, so screens can reload cheaply.
    @Published private(set) var revision = 0

    /// Coalesced "something a surface cares about changed" signal. Declared here, where the
    /// published setters are visible, so the properties themselves can stay `private(set)`.
    var surfaceSignal: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            $pending.map { _ in () }.eraseToAnyPublisher(),
            $isProcessing.map { _ in () }.eraseToAnyPublisher(),
            $revision.map { _ in () }.eraseToAnyPublisher(),
        ]).eraseToAnyPublisher()
    }

    func set(pending: Int) {
        onMain { if self.pending != pending { self.pending = pending } }
    }

    func set(processing: Bool, stage: String?) {
        onMain {
            if self.isProcessing != processing { self.isProcessing = processing }
            if self.stage != stage { self.stage = stage }
        }
    }

    func noteProcessed() {
        onMain {
            self.processedCount += 1
            self.revision += 1
        }
    }

    func noteSkipped() {
        onMain { self.skippedCount += 1 }
    }

    func noteDropped(_ count: Int = 1) {
        onMain { self.droppedCount += count }
    }

    func noteFailure(_ message: String) {
        onMain {
            self.failedCount += 1
            self.lastError = message
        }
    }

    func noteSummary(at date: Date) {
        onMain {
            self.lastSummaryAt = date
            self.revision += 1
        }
    }

    func noteChange() {
        onMain { self.revision += 1 }
    }

    func clearError() {
        onMain { self.lastError = nil }
    }

    func set(speakersAwaitingNames speakers: [SpeakerDTO]) {
        onMain {
            guard self.speakersAwaitingNames.map(\.id) != speakers.map(\.id) else { return }
            self.speakersAwaitingNames = speakers
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
