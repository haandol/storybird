import AVFoundation
import AVKit
import StorybirdCore
import SwiftUI

private final class VideoTimeObserverBox: @unchecked Sendable {
    weak var player: AVPlayer?
    var token: Any?

    deinit {
        if let token {
            player?.removeTimeObserver(token)
        }
    }
}

struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    /// Creates a stable AppKit player surface while Storybird owns playback controls.
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // AVKit otherwise analyzes text/objects in paused frames by default.
        // Screen recordings are text-heavy; the editor owns its own overlays.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    /// Keeps the reusable AppKit view attached to the current project player.
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    /// Detaches media resources when the project view leaves the SwiftUI tree.
    static func dismantleNSView(
        _ view: AVPlayerView,
        coordinator: ()
    ) {
        view.player = nil
    }
}

/// Owns player lifetime without forwarding every frame to the whole editor.
@MainActor
final class VideoPlaybackOwner: ObservableObject {
    let playback: VideoPlaybackModel

    init(url: URL, project: DemoProject) {
        playback = VideoPlaybackModel(url: url, project: project)
    }
}

/// Only controls and overlays that display playback time subscribe to its clock.
struct PlaybackDrivenView<Content: View>: View {
    @ObservedObject var playback: VideoPlaybackModel
    let content: (VideoPlaybackModel) -> Content

    init(playback: VideoPlaybackModel, @ViewBuilder content: @escaping (VideoPlaybackModel) -> Content) {
        self.playback = playback
        self.content = content
    }

    var body: some View { content(playback) }
}

@MainActor
final class VideoPlaybackModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double
    @Published private(set) var errorMessage: String?
    private(set) var frameDuration = CMTime(value: 1, timescale: 30)

    let player: AVPlayer
    private let timeObserver = VideoTimeObserverBox()
    private var rebuildTask: Task<Void, Never>?
    private var rebuildID = UUID()

    /// Creates one player whose periodic observer drives every preview layer on the same clock.
    init(url: URL, project: DemoProject) {
        duration = max(project.timelineDuration, 0)
        player = AVPlayer()
        timeObserver.player = player
        installTimeObserver(interval: frameDuration)
        rebuild(url: url, project: project)
    }

    /// Replaces the observation cadence with the output frame grid, so high-rate
    /// and accelerated clips do not leave overlays on a slower 30Hz clock.
    private func installTimeObserver(interval: CMTime) {
        if let token = timeObserver.token { player.removeTimeObserver(token) }
        frameDuration = interval
        timeObserver.token = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let currentTime = min(
                    max(CMTimeGetSeconds(time), 0),
                    self.duration
                )
                if self.currentTime != currentTime { self.currentTime = currentTime }
                let isPlaying = self.player.rate != 0
                if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
            }
        }
    }

    /// Replaces the current composition only if this is still the newest load.
    /// Cancelled/stale loads cannot restore obsolete audio or an emptied timeline.
    func rebuild(url: URL, project: DemoProject) {
        rebuildTask?.cancel()
        let requestID = UUID()
        rebuildID = requestID
        let resumeTime = min(currentTime, project.timelineDuration)
        errorMessage = nil
        guard !project.clips.isEmpty else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            isPlaying = false
            return
        }
        rebuildTask = Task {
            do {
                let result = try await EditedVideoAssetBuilder.build(
                    project: project,
                    sourceURL: url
                )
                let sourceAsset = AVURLAsset(url: url)
                let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .video)
                guard let sourceTrack = sourceTracks.first else { throw LayeredVideoExportError.missingVideoTrack }
                let cadence = try await VideoFrameCadence.frameDuration(
                    sourceAsset: sourceAsset, sourceTrack: sourceTrack, project: project
                )
                try Task.checkCancellation()
                guard rebuildID == requestID else { return }
                let item = AVPlayerItem(asset: result.asset)
                AmplifiedAudioFiles.retainLeases(from: result.asset, on: item)
                item.audioMix = result.audioMix
                player.replaceCurrentItem(with: item)
                installTimeObserver(interval: cadence)
                duration = max(result.duration, 0)
                seek(to: resumeTime)
            } catch {
                guard rebuildID == requestID, !Task.isCancelled else { return }
                player.pause()
                player.replaceCurrentItem(with: nil)
                duration = 0
                currentTime = 0
                isPlaying = false
                errorMessage =
                    "The edited preview could not be composed: \(error.localizedDescription)"
            }
        }
    }

    /// Toggles the raw recording while keeping the overlay clock tied to player time.
    func togglePlayback() {
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    /// Seeks the video and overlay preview to one bounded project-time value.
    func seek(to seconds: Double) {
        let bounded = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = bounded
    }
}
