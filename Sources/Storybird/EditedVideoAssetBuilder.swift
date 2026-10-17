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
        audioMix: AVAudioMix?,
        videoComposition: AVVideoComposition
    ) {
        let mediaSources = try await VideoMediaSources.load(project: project, sourceURL: sourceURL, audio: true)
        guard let primary = mediaSources[project.id] else { throw LayeredVideoExportError.missingVideoTrack }
        let sourceTrack = primary.track
        let sourceAudioTrack = primary.audioTrack
        let sourceAudioTimeRange = primary.audioRange
        let timeline = try VideoTimelineCompositionBuilder.build(
            project: project,
            sourceTrack: sourceTrack,
            sourceAudioTrack: sourceAudioTrack,
            sourceAudioTimeRange: sourceAudioTimeRange,
            mediaSources: mediaSources
        )
        VideoMediaSources.retainAudio(mediaSources, on: timeline.asset)
        let audio = try await NarrationCompositionBuilder.addNarrations(
            project: project,
            assetsDirectory: sourceURL.deletingLastPathComponent(),
            composition: timeline.asset,
            sourceAudioTrack: timeline.audioTrack
        )
        let composition = try await MediaVideoComposition.make(project: project, track: timeline.track,
            duration: timeline.duration, sources: mediaSources, sourceURL: sourceURL)
        return (
            timeline.asset,
            CMTimeGetSeconds(timeline.duration),
            audio.audioMix,
            composition
        )
    }
}
