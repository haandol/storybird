import Foundation

public enum MediaAssetEditor {
    /// Inserts a new clip referencing an owned source. Images have an explicit
    /// display duration; videos retain their selected source range and speed.
    public static func place(assetID: UUID, in project: DemoProject, destination: Int,
                             duration: Double? = nil, sourceStart: Double = 0,
                             sourceEnd: Double? = nil, playbackRate: Double = 1) throws -> DemoProject {
        guard let asset = project.availableMediaAssets.first(where: { $0.id == assetID }) else {
            throw VideoProjectValidationError.invalidMediaAsset(assetID)
        }
        guard (0...project.clips.count).contains(destination) else { throw VideoTimelineEditError.invalidDestination }
        let clip: VideoClip
        switch asset.kind {
        case .video:
            guard duration == nil else { throw VideoTimelineEditError.invalidTrim }
            clip = VideoClip(sourceStart: sourceStart, sourceEnd: sourceEnd ?? asset.duration ?? 0,
                playbackRate: playbackRate, mediaAssetID: assetID == project.id ? nil : assetID)
        case .image:
            guard let duration, duration.isFinite, duration > 0,
                  sourceStart == 0, sourceEnd == nil, playbackRate == 1 else {
                throw VideoTimelineEditError.invalidFreeze
            }
            clip = VideoClip(kind: .image, sourceStart: 0, sourceEnd: 0,
                freezeDuration: duration, mediaAssetID: assetID)
        }
        var result = project
        result.clips.insert(clip, at: destination)
        result = VideoTimelineEditor.remapContentLayers(result)
        try VideoProjectValidator.validate(result)
        return result
    }
}
