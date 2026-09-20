import SwiftUI
import UIKit

/// Live clipping. Presentation only — it reads the recorder and never drives the capture
/// loop, so dismissing or rebuilding this view cannot affect a session.
struct ListenView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var library: AudioLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pipeline: PipelineStatus

    @State private var showingClips = false
    @State private var showingPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                ClipperBackground(isRecording: recorder.state.isCapturingAudio)

                ScrollView {
                    VStack(spacing: 18) {
                        GlassPanel(cornerRadius: 34) {
                            statusBlock
                                .padding(.vertical, 32)
                                .padding(.horizontal, 20)
                        }

                        transport
                        signalRow
                        processingRow
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Clipper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingClips = true
                    } label: {
                        Label("Buffer", systemImage: "waveform.circle")
                    }
                }
            }
            .sheet(isPresented: $showingClips) { ClipsView() }
            .sheet(item: $pipeline.namingPrompt) { speaker in
                SpeakerNamingSheet(speaker: speaker)
            }
            .alert("Microphone access needed", isPresented: $showingPermissionAlert) {
                Button("Open Settings") { openSystemSettings() }
                Button("Not now", role: .cancel) { recorder.acknowledgeError() }
            } message: {
                Text("Clipper listens through the microphone, so it needs permission in Settings › Privacy & Security › Microphone.")
            }
            .onChange(of: recorder.state) { _, newState in
                if newState == .denied { showingPermissionAlert = true }
            }
            .onAppear { library.bootstrap() }
        }
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(spacing: 16) {
            RecordingIndicator(state: recorder.state)

            if recorder.state.isActive, let started = recorder.sessionStartedAt {
                sessionClock(from: started)
            } else {
                idleHeadline
            }

            if recorder.state.isCapturingAudio {
                LevelMeter(levelDB: recorder.levelDB,
                           noiseFloorDB: recorder.noiseFloorDB,
                           isSpeech: recorder.state.isSpeechDetected)
                    .frame(height: 26)
                    .padding(.horizontal, 8)
            }

            if let detail = recorder.state.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            if recorder.lowConfidence && recorder.state.isCapturingAudio {
                Label("Noisy — this audio may transcribe poorly", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: recorder.state)
    }

    /// Elapsed session time, plus the number the product is actually about: how much speech
    /// was heard, not how long the app was open.
    private func sessionClock(from started: Date) -> some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ClipperFormat.clock(context.date.timeIntervalSince(started)))
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(recorder.state.isCapturingAudio ? .primary : .secondary)
            }
            Text("\(ClipperFormat.compactDuration(recorder.speechSeconds)) of speech")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var idleHeadline: some View {
        VStack(spacing: 6) {
            Text("00:00")
                .font(.system(size: 60, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("Tap Start, then use your phone normally")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 12) {
            Button {
                recorder.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.state.isActive ? "stop.fill" : "mic.fill")
                        .font(.headline)
                    Text(recorder.state.isActive ? "Stop" : "Start")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentTransition(.opacity)
            }
            .prominentGlass(tint: recorder.state.isActive ? .red : .accentColor)
            .sensoryFeedback(.impact(weight: .medium), trigger: recorder.state.isActive)

            if recorder.state.canPause || recorder.state.canResume {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(recorder.state.canResume ? "Resume" : "Pause",
                          systemImage: recorder.state.canResume ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: recorder.state.canPause || recorder.state.canResume)
    }

    // MARK: - Signal

    /// What the microphone is actually doing. Every line here is a fact read back from the
    /// audio session, not an assumption.
    private var signalRow: some View {
        VStack(spacing: 0) {
            if recorder.state.isActive {
                infoLine(icon: recorder.isUsingBuiltInMic ? "iphone" : "exclamationmark.triangle",
                         text: recorder.inputName ?? "Microphone",
                         detail: recorder.isUsingBuiltInMic ? "Built-in" : "Not the built-in mic",
                         tint: recorder.isUsingBuiltInMic ? .secondary : .orange)
                Divider().padding(.leading, 34)
                infoLine(icon: recorder.otherAudioPlaying ? "music.note" : "speaker.slash",
                         text: recorder.otherAudioPlaying ? "Another app is playing audio" : "No other audio",
                         detail: settings.letOtherAppsPlay ? "Mixing" : "Exclusive",
                         tint: .secondary)
                Divider().padding(.leading, 34)
                infoLine(icon: "waveform.path.ecg",
                         text: "Signal \(Int(recorder.snrDB)) dB over noise",
                         detail: "Floor \(Int(recorder.noiseFloorDB)) dB",
                         tint: .secondary)
                Divider().padding(.leading, 34)
            }

            Button {
                showingClips = true
            } label: {
                infoLine(icon: "waveform.circle",
                         text: bufferSummary,
                         detail: "View",
                         tint: .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoLine(icon: String, text: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var bufferSummary: String {
        let count = library.clips.count
        let clipWord = count == 1 ? "clip" : "clips"
        if count == 0 { return "\(settings.bufferMinutes)-minute rolling buffer" }
        return "\(count) \(clipWord) buffered · \(settings.bufferMinutes) min"
    }

    // MARK: - Processing

    @ViewBuilder
    private var processingRow: some View {
        if pipeline.pending > 0 || pipeline.isProcessing || pipeline.lastError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if pipeline.isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray.full")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(pipeline.stage ?? "Queued")
                        .font(.footnote.weight(.medium))
                    Spacer()
                    Text("\(pipeline.pending)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let error = pipeline.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Dismiss") { pipeline.clearError() }
                            .font(.caption)
                    }
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.opacity)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Live input meter, drawn from the real level and the real noise floor.
///
/// The floor marker is the point of it: it shows *why* the detector is or is not opening,
/// which turns "Clipper isn't hearing me" into something the user can see and act on.
struct LevelMeter: View {
    let levelDB: Float
    let noiseFloorDB: Float
    let isSpeech: Bool

    private let range: ClosedRange<Float> = -65...0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let level = fraction(levelDB)
            let floor = fraction(noiseFloorDB)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))

                Capsule()
                    .fill(isSpeech ? Color.red.opacity(0.75) : Color.accentColor.opacity(0.55))
                    .frame(width: max(3, width * CGFloat(level)))
                    .animation(.linear(duration: 0.1), value: level)

                Rectangle()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 1.5)
                    .offset(x: width * CGFloat(floor))
                    .animation(.easeInOut(duration: 0.6), value: floor)
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .bottomLeading) {
                Text(isSpeech ? "speech" : "quiet")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(isSpeech ? "Speech detected" : "No speech")
    }

    private func fraction(_ value: Float) -> Float {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
