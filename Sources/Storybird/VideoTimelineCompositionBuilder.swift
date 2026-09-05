import AVFoundation
import Foundation
import StorybirdCore

struct VideoTimelineComposition {
    let asset: AVMutableComposition
    let track: AVMutableCompositionTrack
    let duration: CMTime
}

enum VideoTimelineCompositionBuilder {
    /// Builds the shared edited clock used by both preview playback and MP4 export.
    static func build(
        project: DemoProject,
        sourceTrack: AVAssetTrack
    ) throws -> VideoTimelineComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let schedule = VideoTimelineSchedule(project: project)
        guard schedule.isStructurallyValid else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        var cursor = CMTime.zero

        for item in schedule.items {
            switch item {
            case let .card(card):
                try insertStillFrame(
                    at: card.sourceFrameTime,
                    duration: card.projectEnd - card.projectStart,
                    sourceTrack: sourceTrack,
                    compositionTrack: track,
                    cursor: &cursor,
                    sourceDuration: project.recording?.duration ?? 0
                )
            case let .clip(scheduled):
                let sourceRange = sourceRange(for: scheduled.clip)
                try track.insertTimeRange(
                    sourceRange,
                    of: sourceTrack,
                    at: cursor
                )
                let outputDuration = CMTime(
                    seconds: scheduled.projectEnd
                        - scheduled.projectStart,
                    preferredTimescale: 600
                )
                track.scaleTimeRange(
                    CMTimeRange(
                        start: cursor,
                        duration: sourceRange.duration
                    ),
                    toDuration: outputDuration
                )
                cursor = cursor + outputDuration
            }
        }

        return VideoTimelineComposition(
            asset: composition,
            track: track,
            duration: cursor
        )
    }

    private static func sourceRange(
        for clip: VideoClip
    ) -> CMTimeRange {
        switch clip.kind {
        case .video:
            return CMTimeRange(
                start: CMTime(
                    seconds: clip.sourceStart,
                    preferredTimescale: 600
                ),
                duration: CMTime(
                    seconds: clip.sourceEnd - clip.sourceStart,
                    preferredTimescale: 600
                )
            )
        case .freeze:
            return CMTimeRange(
                start: CMTime(
                    seconds: clip.sourceStart,
                    preferredTimescale: 600
                ),
                duration: CMTime(value: 1, timescale: 600)
            )
        }
    }

    /// Inserts a stretched source frame behind a full-screen title or CTA card.
    private static func insertStillFrame(
        at sourceTime: Double,
        duration: Double,
        sourceTrack: AVAssetTrack,
        compositionTrack: AVMutableCompositionTrack,
        cursor: inout CMTime,
        sourceDuration: Double
    ) throws {
        let safeTime = min(
            max(sourceTime, 0),
            max(sourceDuration - 1.0 / 600, 0)
        )
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: safeTime, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 600)
        )
        try compositionTrack.insertTimeRange(
            sourceRange,
            of: sourceTrack,
            at: cursor
        )
        let outputDuration = CMTime(
            seconds: duration,
            preferredTimescale: 600
        )
        compositionTrack.scaleTimeRange(
            CMTimeRange(start: cursor, duration: sourceRange.duration),
            toDuration: outputDuration
        )
        cursor = cursor + outputDuration
    }
}
