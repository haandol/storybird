import AVFoundation
import AVKit
import SwiftUI

struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var isPreparing = false
    var onPhaseChange: (@MainActor (VideoPreviewPhase) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Creates a stable AppKit player surface while Storybird owns playback controls.
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // AVKit otherwise analyzes text/objects in paused frames by default.
        // Screen recordings are text-heavy; the editor owns its own overlays.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        context.coordinator.bind(view: view, player: player, isPreparing: isPreparing, onPhaseChange: onPhaseChange)
        return view
    }

    /// Keeps the reusable AppKit view attached to the current project player.
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
            context.coordinator.bind(view: view, player: player, isPreparing: isPreparing, onPhaseChange: onPhaseChange)
        } else {
            context.coordinator.onPhaseChange = onPhaseChange
            context.coordinator.setPreparing(isPreparing)
        }
    }

    /// Detaches media resources when the project view leaves the SwiftUI tree.
    static func dismantleNSView(
        _ view: AVPlayerView,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        view.player = nil
    }

    /// Observe first-frame readiness, not a timer or asset metadata alone.
    /// Queued notifications from a detached surface cannot reveal a newer view.
    @MainActor
    final class Coordinator {
        var onPhaseChange: (@MainActor (VideoPreviewPhase) -> Void)?
        private weak var view: AVPlayerView?
        private weak var player: AVPlayer?
        private weak var item: AVPlayerItem?
        private var frameObservation: NSKeyValueObservation?
        private var playerObservation: NSKeyValueObservation?
        private var itemObservation: NSKeyValueObservation?
        private var generation = UUID()
        private var lastPhase: VideoPreviewPhase?
        private var isPreparing = false

        func bind(view: AVPlayerView, player: AVPlayer, isPreparing: Bool = false,
                  onPhaseChange: (@MainActor (VideoPreviewPhase) -> Void)?) {
            invalidate()
            self.view = view
            self.player = player
            self.isPreparing = isPreparing
            self.onPhaseChange = onPhaseChange
            let token = generation
            frameObservation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh(generation: token) }
            }
            playerObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh(generation: token) }
            }
        }

        func setPreparing(_ value: Bool) {
            guard value != isPreparing else { return }
            isPreparing = value
            lastPhase = nil
            let token = generation
            Task { @MainActor [weak self] in self?.refresh(generation: token) }
        }

        func invalidate() {
            generation = UUID()
            frameObservation?.invalidate()
            playerObservation?.invalidate()
            itemObservation?.invalidate()
            frameObservation = nil
            playerObservation = nil
            itemObservation = nil
            view = nil
            player = nil
            item = nil
            lastPhase = nil
            onPhaseChange = nil
        }

        private func refresh(generation token: UUID) {
            guard generation == token, let view, let player else { return }
            if item !== player.currentItem {
                itemObservation?.invalidate()
                item = player.currentItem
                lastPhase = nil
                itemObservation = item?.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refresh(generation: token) }
                }
            }
            let phase = VideoPreviewPhase.resolve(
                isPreparing: isPreparing, itemStatus: item?.status,
                isReadyForDisplay: view.isReadyForDisplay, errorMessage: item?.error?.localizedDescription
            )
            guard phase != lastPhase else { return }
            lastPhase = phase
            onPhaseChange?(phase)
        }
    }
}
