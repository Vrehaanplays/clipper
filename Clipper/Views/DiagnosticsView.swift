import AVFoundation
import Speech
import SwiftUI

/// What is actually true about this device and this build.
///
/// Several capabilities in Clipper are device-, SDK- or permission-dependent, and the
/// honest thing is to show which ones are live rather than letting the user guess from
/// behaviour. Everything on this screen is read from the system at the moment it appears.
struct DiagnosticsView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var library: AudioLibrary
    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var stats = StoreStatsDTO()
    @State private var modelStatus = "Checking…"
    @State private var embeddingDimensions = 0
    @State private var latency: (samples: Int, mean: TimeInterval, worst: TimeInterval) = (0, 0, 0)
    @State private var failedJobs: [JobSnapshot] = []
    @State private var saveError: String?
    @State private var isReindexing = false

    private let store = ClipperStore.shared
    private let surfaces = SurfaceCoordinator.shared
    private let session = AudioSessionManager.shared
    private let transcriber = OnDeviceSpeechTranscriber()

    var body: some View {
        List {
            capabilitySection
            audioSection
            pipelineSection
            databaseSection
            searchSection
            surfaceSection
            maintenanceSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Capabilities

    private var capabilitySection: some View {
        Section {
            capability("Microphone permission",
                       ok: session.permission == .granted,
                       detail: permissionLabel)
            capability("Speech recognition permission",
                       ok: SFSpeechRecognizer.authorizationStatus() == .authorized,
                       detail: speechAuthLabel)
            capability("On-device recognition",
                       ok: transcriber.supportsOnDevice,
                       detail: transcriber.supportsOnDevice
                           ? "Available"
                           : "Not downloaded yet — Clipper will not use a server instead")
            capability("On-device language model",
                       ok: modelStatus.contains("available"),
                       detail: modelStatus)
            capability("Sentence embeddings",
                       ok: embeddingDimensions > 0,
                       detail: embeddingDimensions > 0
                           ? "\(embeddingDimensions) dimensions"
                           : "Unavailable — search is lexical only")
            capability("iPhone search indexing",
                       ok: SpotlightIndexer.shared.isSupported,
                       detail: SpotlightIndexer.shared.isSupported ? "Available" : "Unavailable")
        } header: {
            Text("Capabilities")
        } footer: {
            Text("Anything marked unavailable degrades a feature rather than breaking the app. Summaries fall back to sentence selection; search falls back to term matching.")
        }
    }

    private var permissionLabel: String {
        switch session.permission {
        case .granted: return "Granted"
        case .denied: return "Denied in iOS Settings"
        case .undetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var speechAuthLabel: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "Granted"
        case .denied: return "Denied in iOS Settings"
        case .restricted: return "Restricted on this device"
        case .notDetermined: return "Asked on the first transcription"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            DetailRow(label: "State", value: recorder.state.title, systemImage: "waveform")
            DetailRow(label: "Input", value: recorder.inputName ?? "—", systemImage: "mic")
            DetailRow(label: "Built-in mic",
                      value: recorder.isUsingBuiltInMic ? "Yes" : "No",
                      systemImage: "iphone")
            DetailRow(label: "Other audio playing",
                      value: recorder.otherAudioPlaying ? "Yes" : "No",
                      systemImage: "music.note")
            DetailRow(label: "Hardware rate",
                      value: session.sampleRate > 0 ? "\(Int(session.sampleRate)) Hz" : "—",
                      systemImage: "dial.medium")
            DetailRow(label: "IO buffer",
                      value: String(format: "%.0f ms", session.ioBufferDuration * 1000),
                      systemImage: "timer")
            if let plan = session.activePlan {
                DetailRow(label: "Session mode", value: plan.mode.rawValue, systemImage: "slider.horizontal.3")
                DetailRow(label: "Mixing with others",
                          value: plan.options.contains(.mixWithOthers) ? "Yes" : "No",
                          systemImage: "square.on.square")
                DetailRow(label: "Voice processing",
                          value: plan.voiceProcessing ? "On" : "Off",
                          systemImage: "waveform.badge.minus")
            }
            DetailRow(label: "Level",
                      value: String(format: "%.0f dB (floor %.0f)", recorder.levelDB, recorder.noiseFloorDB),
                      systemImage: "chart.bar")
        } header: {
            Text("Audio session")
        } footer: {
            Text("Read back from AVAudioSession, so this is what iOS actually granted — not what Clipper asked for.")
        }
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        Section {
            DetailRow(label: "Queued", value: "\(pipeline.pending)", systemImage: "tray.full")
            DetailRow(label: "Processed", value: "\(pipeline.processedCount)", systemImage: "checkmark.circle")
            DetailRow(label: "Skipped as non-speech",
                      value: "\(pipeline.skippedCount)",
                      systemImage: "speaker.slash")
            DetailRow(label: "Dropped for backpressure",
                      value: "\(pipeline.droppedCount)",
                      systemImage: "arrow.down.to.line")
            DetailRow(label: "Failures", value: "\(pipeline.failedCount)", systemImage: "exclamationmark.triangle")
            if let stage = pipeline.stage {
                DetailRow(label: "Current stage", value: stage, systemImage: "gearshape")
            }

            if !failedJobs.isEmpty {
                ForEach(failedJobs, id: \.id) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.kind.rawValue)
                            .font(.caption.weight(.medium))
                        Text("gave up after \(job.attempts) attempts")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Button("Retry failed work") {
                    Task {
                        _ = await store.retryFailedJobs()
                        PipelineCoordinator.shared.resumeIfNeeded()
                        await load()
                    }
                }
            }
        } header: {
            Text("Pipeline")
        } footer: {
            Text("Dropped items are utterances discarded because the queue was full; the lowest-quality one is sacrificed first. A non-zero count means the device could not keep up.")
        }
    }

    // MARK: - Database

    private var databaseSection: some View {
        Section {
            DetailRow(label: "Store size",
                      value: ByteCountFormatter.string(fromByteCount: ClipperDatabase.shared.storeByteSize, countStyle: .file),
                      systemImage: "externaldrive")
            DetailRow(label: "Sessions", value: "\(stats.sessions)", systemImage: "mic")
            DetailRow(label: "Audio rows", value: "\(stats.audioSegments)", systemImage: "waveform")
            DetailRow(label: "Transcript lines", value: "\(stats.transcriptSegments)", systemImage: "text.alignleft")
            DetailRow(label: "Conversations", value: "\(stats.conversations)", systemImage: "bubble.left.and.bubble.right")
            DetailRow(label: "Voices", value: "\(stats.speakers) (\(stats.namedSpeakers) named)", systemImage: "person.wave.2")
            DetailRow(label: "Memories", value: "\(stats.memories)", systemImage: "brain")
            DetailRow(label: "Summaries", value: "\(stats.summaries)", systemImage: "doc.text")
            DetailRow(label: "Graph", value: "\(stats.nodes) nodes, \(stats.edges) edges", systemImage: "point.3.connected.trianglepath.dotted")
            DetailRow(label: "Contradictions",
                      value: "\(stats.contradictions) (\(stats.openContradictions) open)",
                      systemImage: "exclamationmark.2")

            if let note = ClipperDatabase.shared.recoveryNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if ClipperDatabase.shared.isEphemeral {
                Label("Running without storage — nothing is being saved.",
                      systemImage: "externaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let saveError {
                Label("Last save error: \(saveError)", systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Database")
        } footer: {
            Text("Schema version 1. A store that fails to open is moved aside into Corrupt/ and rebuilt rather than deleted.")
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            DetailRow(label: "Indexed documents", value: "\(stats.documents)", systemImage: "doc.on.doc")
            DetailRow(label: "Index postings", value: "\(stats.postings)", systemImage: "number")
            DetailRow(label: "Postings per document",
                      value: stats.documents > 0
                          ? String(format: "%.0f", Double(stats.postings) / Double(stats.documents))
                          : "—",
                      systemImage: "divide")
            if latency.samples > 0 {
                DetailRow(label: "Mean search time",
                          value: String(format: "%.0f ms", latency.mean * 1000),
                          systemImage: "timer")
                DetailRow(label: "Worst search time",
                          value: String(format: "%.0f ms", latency.worst * 1000),
                          systemImage: "timer")
                DetailRow(label: "Measured over", value: "\(latency.samples) searches", systemImage: "chart.bar")
            } else {
                Text("Run a search to measure latency.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Search index")
        } footer: {
            Text("Measured on this device, from real searches in this session. Term lookup is a B-tree seek per word; nothing scans the whole store.")
        }
    }

    // MARK: - Surfaces

    private var surfaceSection: some View {
        Section {
            capability("App group (widget data)",
                       ok: surfaces.appGroupAvailable,
                       detail: surfaces.appGroupAvailable
                           ? "Readable"
                           : "Not provisioned — the widget shows a static state")
            capability("Live Activities allowed by iOS",
                       ok: surfaces.liveActivitiesEnabled,
                       detail: surfaces.liveActivitiesEnabled ? "Yes" : "Off in iOS Settings")
            DetailRow(label: "Live Activity running",
                      value: surfaces.liveActivityRunning ? "Yes" : "No",
                      systemImage: "rectangle.on.rectangle")
        } header: {
            Text("Widget and Live Activity")
        } footer: {
            Text("An app group cannot be provisioned by a free Apple ID, so a sideloaded build often cannot share status with its widget. Live Activities need no app group and work either way.")
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            Button {
                isReindexing = true
                PipelineCoordinator.shared.reindexEverything()
            } label: {
                HStack {
                    Label("Rebuild the search index", systemImage: "arrow.clockwise")
                    if isReindexing {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isReindexing)

            Button {
                PipelineCoordinator.shared.regenerateSummaries(forDay: Date())
            } label: {
                Label("Regenerate today's summaries", systemImage: "doc.badge.arrow.up")
            }

            Button {
                PipelineCoordinator.shared.requestNamingPromptRefresh()
            } label: {
                Label("Check for voices to name", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Maintenance")
        } footer: {
            Text("Rebuilding the index re-embeds every document and can take minutes on a large store. It runs in the background and is safe to leave.")
        }
    }

    // MARK: - Pieces

    private func capability(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(ok ? .green : .orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        stats = await store.stats()
        failedJobs = await store.failedJobs(limit: 8)
        saveError = await store.lastSaveError
        modelStatus = await SummarizerPool.shared.modelStatus()
        embeddingDimensions = await Embedder.shared.dimensions
        latency = await SearchService.shared.latencyReport()
        isReindexing = false
    }
}
