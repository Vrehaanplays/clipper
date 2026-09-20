import Combine
import Foundation
import WidgetKit

/// Keeps the Home Screen widget and the Live Activity in step with reality.
///
/// Both surfaces read the same `ClipperPhase`, derived from the recorder's real state, so
/// neither can claim Clipper is listening when the engine is stopped.
///
/// ## Update budget
/// WidgetKit rate-limits timeline reloads, and burning the budget on a counter that ticks
/// ten times a second means the widget stops updating when something important happens. So:
///
/// - **Phase changes** (started, speech detected, interrupted, stopped) reload immediately.
/// - **Counter changes** (speech seconds, queue depth) are throttled and additionally
///   rate-limited to one reload a minute.
/// - Elapsed time in the widget and the Live Activity is rendered by the system from a
///   date, not pushed as a string, so it counts up with no updates at all.
final class SurfaceCoordinator: ObservableObject {
    static let shared = SurfaceCoordinator()

    private let recorder: AudioRecorder
    private let pipeline: PipelineCoordinator
    private let settings: AppSettings
    private let store: ClipperStore
    private let group = AppGroupStore.shared
    private let liveActivity = LiveActivityController.shared

    private var cancellables: Set<AnyCancellable> = []
    private var lastWidgetReload = Date.distantPast
    private var lastPhase: ClipperPhase?
    private var startedActivityFor: UUID?

    /// Cached content for the widget's idle state, refreshed on a slow cadence.
    private var cachedMemoryHeadline: String?
    private var cachedSummaryHeadline: String?
    private var cachedMemoryCount = 0
    private var contentRefreshedAt = Date.distantPast

    private let minimumWidgetInterval: TimeInterval = 60

    private init(recorder: AudioRecorder = .shared,
                 pipeline: PipelineCoordinator = .shared,
                 settings: AppSettings = .shared,
                 store: ClipperStore = .shared) {
        self.recorder = recorder
        self.pipeline = pipeline
        self.settings = settings
        self.store = store
    }

    /// Called once at launch, after the pipeline has bootstrapped.
    func start() {
        guard cancellables.isEmpty else { return }

        liveActivity.endStrandedActivities()

        // Phase transitions are the ones that matter; push them straight through.
        recorder.phasePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish(immediate: true) }
            .store(in: &cancellables)

        // Counters: coalesced here, then rate-limited again inside `publish`.
        Publishers.Merge(recorder.meterPublisher, pipeline.status.surfaceSignal)
            .throttle(for: .seconds(10), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.publish(immediate: false) }
            .store(in: &cancellables)

        // The Live Activity setting is independent of the widget setting, and turning it
        // off must end an activity that is already on screen.
        settings.$liveActivityEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.publish(immediate: true)
                } else {
                    self.liveActivity.hide()
                    self.startedActivityFor = nil
                }
            }
            .store(in: &cancellables)

        settings.$widgetContentEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish(immediate: true) }
            .store(in: &cancellables)

        publish(immediate: true)
    }

    /// Foregrounding, and after a scene rebuild.
    func refresh() {
        liveActivity.reattachIfNeeded()
        contentRefreshedAt = .distantPast
        publish(immediate: true)
    }

    /// The user asked to dismiss the Live Activity from inside the app.
    func hideLiveActivity() {
        liveActivity.hide()
        startedActivityFor = nil
    }

    // MARK: - Publishing

    private func publish(immediate: Bool) {
        let state = recorder.state
        let phase = state.phase
        let config = settings.config
        let status = pipeline.status

        let contentState = ClipperActivityAttributes.ContentState(
            phase: phase,
            speechSeconds: recorder.speechSeconds,
            pendingJobs: status.pending,
            isProcessing: status.isProcessing,
            lowConfidence: recorder.lowConfidence,
            pausedAt: phase == .paused ? Date() : nil
        )

        updateLiveActivity(phase: phase, contentState: contentState, config: config)

        // Refresh the idle content the widget shows, at most every few minutes.
        if Date().timeIntervalSince(contentRefreshedAt) > 180 {
            contentRefreshedAt = Date()
            Task { [weak self] in await self?.refreshCachedContent() }
        }

        writeSnapshot(phase: phase, config: config)

        let phaseChanged = phase != lastPhase
        lastPhase = phase
        reloadWidgetIfAllowed(force: immediate && phaseChanged)
    }

    private func updateLiveActivity(phase: ClipperPhase,
                                    contentState: ClipperActivityAttributes.ContentState,
                                    config: ClipperConfig) {
        guard config.liveActivityEnabled else { return }

        guard phase.isSessionActive,
              let sessionID = recorder.sessionID,
              let startedAt = recorder.sessionStartedAt else {
            if startedActivityFor != nil {
                liveActivity.end(finalState: contentState)
                startedActivityFor = nil
            }
            return
        }

        if startedActivityFor != sessionID {
            liveActivity.start(sessionID: sessionID, startedAt: startedAt, state: contentState)
            startedActivityFor = sessionID
        } else {
            liveActivity.update(contentState)
        }
    }

    private func writeSnapshot(phase: ClipperPhase, config: ClipperConfig) {
        let snapshot = ClipperSnapshot(
            phase: phase,
            sessionStartedAt: recorder.sessionStartedAt,
            speechSeconds: recorder.speechSeconds,
            pendingJobs: pipeline.status.pending,
            isProcessing: pipeline.status.isProcessing,
            lowConfidence: recorder.lowConfidence,
            // The widget content switch controls the *content*, not the status: a status-only
            // widget is still useful and still honest.
            recentMemory: config.widgetContentEnabled ? cachedMemoryHeadline : nil,
            recentSummary: config.widgetContentEnabled ? cachedSummaryHeadline : nil,
            memoryCount: cachedMemoryCount,
            updatedAt: Date()
        )
        _ = group.write(snapshot)
    }

    private func reloadWidgetIfAllowed(force: Bool) {
        let elapsed = Date().timeIntervalSince(lastWidgetReload)
        guard force || elapsed >= minimumWidgetInterval else { return }
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refreshCachedContent() async {
        let memories = await store.importantMemories(limit: 1)
        let summary = await store.latestSummary()
        let stats = await store.stats()

        await MainActor.run {
            self.cachedMemoryHeadline = memories.first?.title
            self.cachedSummaryHeadline = summary?.title
            self.cachedMemoryCount = stats.memories
        }
    }

    // MARK: - Diagnostics

    var appGroupAvailable: Bool { group.isAvailable }

    var liveActivitiesEnabled: Bool { liveActivity.areActivitiesEnabled }

    var liveActivityRunning: Bool { liveActivity.isRunning }
}
