import AVFoundation
import Combine
import Foundation

/// Plays a single clip at a time. Deliberately small: play, pause, scrub.
///
/// Playback works while recording is running because the capture session already uses
/// `.playAndRecord`, so no category switch is needed and no segment is disturbed.
final class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    /// Seconds into the clip. Updated a few times a second while playing.
    @Published var position: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private let session = AudioSessionManager.shared

    private override init() { super.init() }

    func isPlaying(_ clip: Clip) -> Bool {
        isPlaying && currentURL == clip.url
    }

    func isLoaded(_ clip: Clip) -> Bool {
        currentURL == clip.url
    }

    // MARK: - Transport

    func toggle(_ clip: Clip) {
        if currentURL == clip.url {
            isPlaying ? pause() : resume()
        } else {
            load(clip)
            resume()
        }
    }

    private func load(_ clip: Clip) {
        stopTicker()
        player?.stop()
        player = nil

        do {
            try session.activateForPlaybackIfNeeded()
            let newPlayer = try AVAudioPlayer(contentsOf: clip.url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            currentURL = clip.url
            duration = newPlayer.duration > 0 ? newPlayer.duration : clip.duration
            position = 0
        } catch {
            currentURL = nil
            duration = 0
            position = 0
            isPlaying = false
        }
    }

    func resume() {
        guard let player else { return }
        try? session.activateForPlaybackIfNeeded()
        if player.play() {
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func stop() {
        player?.stop()
        player = nil
        stopTicker()
        isPlaying = false
        currentURL = nil
        position = 0
        duration = 0
    }

    /// Called by the scrubber. `position` is already the new value.
    func commitScrub() {
        guard let player else { return }
        player.currentTime = max(0, min(position, player.duration))
    }

    /// Drop a clip that is no longer on disk.
    func forgetIfPlaying(_ clip: Clip) {
        if currentURL == clip.url { stop() }
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let player = self.player, self.isPlaying else { return }
            self.position = player.currentTime
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        position = flag ? duration : 0
        stopTicker()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stop()
    }
}
