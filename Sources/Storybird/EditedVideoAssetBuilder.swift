import AVFoundation
import Foundation
import StorybirdCore

enum EditedVideoAssetBuilder {
    /// Builds a playable composition from immutable source ranges so UI playback matches export order and speed.
    static func build(
        project: DemoProject,
        sourceURL: URL
    ) async throws -> (asset: AVAsset, duration: Double) {
        let source = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await source.loadTracks(
            withMediaType: .video
        ).first else {
            throw LayeredVideoExportError.missingVideoTrack
        }
        let timeline = try VideoTimelineCompositionBuilder.build(
            project: project,
            sourceTrack: sourceTrack
        )
        timeline.track.preferredTransform = try await sourceTrack.load(
            .preferredTransform
        )
        return (
            timeline.asset,
            CMTimeGetSeconds(timeline.duration)
        )
    }
}
