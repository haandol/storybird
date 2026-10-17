import AVFoundation
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
    @Published private(set) var isPreparing = true
    private(set) var frameDuration = CMTime(value: 1, timescale: 30)

    let player: AVPlayer
    private let timeObserver = VideoTimeObserverBox()
    private var rateObservation: NSKeyValueObservation?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildID = UUID()

    /// Creates one player whose periodic observer drives every preview layer on the same clock.
    init(url: URL, project: DemoProject) {
        duration = max(project.timelineDuration, 0)
        player = AVPlayer()
        timeObserver.player = player
        installTimeObserver(interval: frameDuration)
        // The player can stop after its final time callback, so button state must
        // observe rate changes independently of the frame clock.
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read the live rate so queued changes cannot restore an older state.
                let isPlaying = self.player.rate != 0
                if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
            }
        }
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
            }
        }
    }

    /// Replaces the current composition only if this is still the newest load.
    /// Cancelled/stale loads cannot restore obsolete audio or an emptied timeline.
    func rebuild(url: URL, project: DemoProject) {
        rebuildTask?.cancel()
        let requestID = UUID()
        rebuildID = requestID
        if !isPreparing { isPreparing = true }
        let resumeTime = min(currentTime, project.timelineDuration)
        errorMessage = nil
        guard !project.clips.isEmpty else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            duration = 0
            currentTime = 0
            isPlaying = false
            isPreparing = false
            return
        }
        rebuildTask = Task {
            do {
                let result = try await EditedVideoAssetBuilder.build(
                    project: project,
                    sourceURL: url
                )
                let cadence = result.videoComposition.frameDuration
                try Task.checkCancellation()
                guard rebuildID == requestID else { return }
                let item = AVPlayerItem(asset: result.asset)
                AmplifiedAudioFiles.retainLeases(from: result.asset, on: item)
                item.audioMix = result.audioMix
                item.videoComposition = result.videoComposition
                player.replaceCurrentItem(with: item)
                installTimeObserver(interval: cadence)
                duration = max(result.duration, 0)
                seek(to: resumeTime)
                isPreparing = false
            } catch {
                guard rebuildID == requestID, !Task.isCancelled else { return }
                player.pause()
                player.replaceCurrentItem(with: nil)
                duration = 0
                currentTime = 0
                isPlaying = false
                errorMessage =
                    "The edited preview could not be composed: \(error.localizedDescription)"
                isPreparing = false
            }
        }
    }

    /// Stops video sound before a separate audio audition begins.
    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Toggles the edited preview while keeping the overlay clock tied to player time.
    func togglePlayback() {
        if player.rate == 0 {
            // AVPlayer stays at the end after completion; Play must rewind first.
            if currentTime >= duration { seek(to: 0) }
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    /// Frame navigation uses the composition's rational grid directly; routing
    /// through the ordinary 600-tick scrub clock would lose 59.94fps boundaries.
    func stepFrame(_ direction: Int) {
        guard !isPreparing, duration > 0, direction != 0 else { return }
        pause()
        guard let target = Self.frameStepTime(from: currentTime, direction: direction, duration: duration, frameDuration: frameDuration) else { return }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
    }

    static func frameStepTime(from time: Double, direction: Int, duration: Double, frameDuration: CMTime) -> CMTime? {
        guard time.isFinite, duration.isFinite, duration > 0, frameDuration.isNumeric, frameDuration > .zero, direction != 0 else { return nil }
        if time >= duration, direction > 0 { return nil }
        let position = max(time, 0) / frameDuration.seconds
        let next = direction > 0 ? floor(position + 1e-9) + 1 : ceil(position - 1e-9) - 1
        let last = max(0, ceil(duration / frameDuration.seconds - 1e-9) - 1)
        let index = min(max(next, 0), last)
        return CMTimeMultiplyByFloat64(frameDuration, multiplier: index)
    }

    func stepClipBoundary(_ direction: Int, in project: DemoProject) {
        guard !isPreparing, direction != 0 else { return }
        let boundaries = Set(VideoTimelineSchedule(project: project).items.flatMap { item -> [Double] in
            if case let .clip(clip) = item { return [clip.projectStart, clip.projectEnd] }; return []
        } + [0, project.timelineDuration]).sorted()
        let next = direction > 0 ? boundaries.first { $0 > currentTime + 1e-9 } : boundaries.last { $0 < currentTime - 1e-9 }
        if let next { pause(); seek(to: next) }
    }

    /// Seeks the video and overlay preview to one bounded project-time value.
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let bounded = min(max(seconds, 0), duration)
        // Native slider normalization can put 7.6/30.4 seconds one floating-point
        // step below the intended clock tick. Round before constructing CMTime
        // so conversion cannot silently seek one 1/600-second tick earlier.
        guard let ticks = Int64(exactly: (bounded * 600).rounded()) else { return }
        player.seek(
            to: CMTime(value: ticks, timescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = bounded
    }
}
