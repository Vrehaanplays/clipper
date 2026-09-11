import SwiftUI
import UIKit

/// The main screen. Presentation only — it reads the recorder and never drives the
/// recording loop. Dismissing or rebuilding this view cannot affect a recording.
struct ContentView: View {
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var settings: AppSettings

    @State private var showingClips = false
    @State private var showingSettings = false
    @State private var showingPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                ClipperBackground(isRecording: recorder.state.isCapturingAudio)

                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    // One glass surface, used to separate status from chrome. The glass
                    // supports the hierarchy; it is not the visual identity.
                    GlassPanel(cornerRadius: 34) {
                        statusBlock
                            .padding(.vertical, 40)
                            .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 24)
                    transport
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .navigationTitle("Clipper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingClips = true
                    } label: {
                        Label("Clips", systemImage: "waveform")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showingClips) { ClipsView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("Microphone access needed", isPresented: $showingPermissionAlert) {
                Button("Open Settings") { openSystemSettings() }
                Button("Not now", role: .cancel) { recorder.acknowledgeError() }
            } message: {
                Text("Clipper records from the microphone, so it needs permission in Settings › Privacy & Security › Microphone.")
            }
            .onChange(of: recorder.state) { _, newState in
                if case .error = newState,
                   AudioSessionManager.shared.permission == .denied {
                    showingPermissionAlert = true
                }
            }
            .onAppear { store.bootstrap() }
        }
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(spacing: 18) {
            RecordingIndicator(state: recorder.state)

            if recorder.state.isActive, let end = recorder.segmentEnd {
                countdown(to: end)
            } else {
                idleHeadline
            }

            if let detail = recorder.state.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.4), value: recorder.state)
    }

    /// Driven entirely by the engine's real segment start and length. A `TimelineView`
    /// only decides when to re-render; it is never the source of the value.
    private func countdown(to end: Date) -> some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Clip.countdownString(end.timeIntervalSince(context.date)))
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(recorder.state.isCapturingAudio ? .primary : .secondary)
            }
            Text("until next clip")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var idleHeadline: some View {
        VStack(spacing: 6) {
            Text(Clip.countdownString(settings.clipDuration))
                .font(.system(size: 68, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("clip length")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 16) {
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

            Button {
                showingClips = true
            } label: {
                Text(bufferSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .animation(.smooth, value: store.clips.count)
        }
    }

    private var bufferSummary: String {
        let count = store.clips.count
        let clipWord = count == 1 ? "clip" : "clips"
        let buffer = settings.bufferMinutes
        if count == 0 {
            return "\(buffer)-minute rolling buffer"
        }
        return "\(count) \(clipWord) · \(buffer) min buffer"
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension AppSettings {
    var clipDuration: TimeInterval { TimeInterval(clipMinutes) * 60 }
}

#Preview {
    ContentView()
        .environmentObject(AudioRecorder.shared)
        .environmentObject(ClipStore.shared)
        .environmentObject(AppSettings.shared)
}
