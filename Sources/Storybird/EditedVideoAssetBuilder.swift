import AVFoundation
import Foundation
import StorybirdCore

enum EditedVideoAssetBuilder {
    /// Builds a playable composition from immutable source ranges so preview keeps
    /// narration, video, and overlays on the same edited project clock.
    static func build(
        project: DemoProject,
        sourceURL: URL
    ) async throws -> (
        asset: AVAsset,
        duration: Double,
        audioMix: AVAudioMix?
    ) {
        let source = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await source.loadTracks(
            withMediaType: .video
        ).first else {
            throw LayeredVideoExportError.missingVideoTrack
        }
        let audioSourceAsset = try await AmplifiedAudioFiles.sourceAsset(
            asset: source, url: sourceURL, gain: project.sourceAudioMuted ? 1 : project.sourceAudioVolume
        )
        // Keep the decoded asset alive while loading and inserting its track.
        defer { withExtendedLifetime(audioSourceAsset) {} }
        let sourceAudioTrack = try await audioSourceAsset.loadTracks(withMediaType: .audio).first
        let sourceAudioTimeRange: CMTimeRange?
        if let sourceAudioTrack {
            sourceAudioTimeRange = try await sourceAudioTrack.load(
                .timeRange
            )
        } else {
            sourceAudioTimeRange = nil
        }
        let timeline = try VideoTimelineCompositionBuilder.build(
            project: project,
            sourceTrack: sourceTrack,
            sourceAudioTrack: sourceAudioTrack,
            sourceAudioTimeRange: sourceAudioTimeRange
        )
        AmplifiedAudioFiles.retainLeases(from: audioSourceAsset, on: timeline.asset)
        timeline.track.preferredTransform = try await sourceTrack.load(
            .preferredTransform
        )
        let audio = try await NarrationCompositionBuilder.addNarrations(
            project: project,
            assetsDirectory: sourceURL.deletingLastPathComponent(),
            composition: timeline.asset,
            sourceAudioTrack: timeline.audioTrack
        )
        return (
            timeline.asset,
            CMTimeGetSeconds(timeline.duration),
            audio.audioMix
        )
    }
}
