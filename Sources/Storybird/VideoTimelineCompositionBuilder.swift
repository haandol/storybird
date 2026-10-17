import AVFoundation
import Foundation
import StorybirdCore

struct VideoTimelineComposition {
    let asset: AVMutableComposition
    let track: AVMutableCompositionTrack
    let audioTrack: AVMutableCompositionTrack?
    let duration: CMTime
}

enum VideoTimelineCompositionBuilder {
    /// Builds the shared edited clock for preview and export, applying every video clip
    /// range and speed change to the optional narration track while leaving cards and
    /// freeze segments silent.
    static func build(
        project: DemoProject,
        sourceTrack: AVAssetTrack,
        sourceAudioTrack: AVAssetTrack? = nil,
        sourceAudioTimeRange: CMTimeRange? = nil,
        mediaSources: [UUID: VideoMediaSource] = [:]
    ) throws -> VideoTimelineComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let hasAudio = sourceAudioTrack != nil || mediaSources.values.contains { $0.audioTrack != nil }
        let audioTrack = hasAudio ? (
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        ) : nil
        let schedule = VideoTimelineSchedule(project: project)
        guard schedule.isStructurallyValid else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        let mediaStartTime = project.recording?.mediaStartTime ?? 0
        var cursor = CMTime.zero

        for item in schedule.items {
            switch item {
            case let .card(card):
                let id = card.sourceClip?.kind == .image ? project.id : (card.sourceClip?.mediaAssetID ?? project.id)
                let selected = mediaSources[id]
                try insertStillFrame(
                    at: (selected?.geometry.mediaStartTime ?? mediaStartTime) + card.sourceFrameTime,
                    endTime: card.projectEnd,
                    sourceTrack: selected?.track ?? sourceTrack,
                    compositionTrack: track,
                    cursor: &cursor,
                    sourceStart: selected?.geometry.mediaStartTime ?? mediaStartTime,
                    sourceDuration: selected?.geometry.duration ?? project.recording?.duration ?? 0
                )
            case let .clip(scheduled):
                let id = scheduled.clip.kind == .image ? project.id : (scheduled.clip.mediaAssetID ?? project.id)
                let selected = mediaSources[id]
                guard id == project.id || selected != nil else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                let videoSource = selected?.track ?? sourceTrack
                let audioSource = selected?.audioTrack ?? (id == project.id ? sourceAudioTrack : nil)
                let audioRange = selected?.audioRange ?? (id == project.id ? sourceAudioTimeRange : nil)
                let selectedStart = selected?.geometry.mediaStartTime ?? mediaStartTime
                if scheduled.clip.kind != .video {
                    try insertStillFrame(at: selectedStart + scheduled.clip.sourceStart,
                        endTime: scheduled.projectEnd, sourceTrack: videoSource,
                        compositionTrack: track, cursor: &cursor, sourceStart: selectedStart,
                        sourceDuration: selected?.geometry.duration ?? project.recording?.duration ?? 0)
                    continue
                }
                let sourceRange = sourceRange(
                    for: scheduled.clip,
                    mediaStartTime: selectedStart
                )
                try track.insertTimeRange(
                    sourceRange,
                    of: videoSource,
                    at: cursor
                )
                // Convert absolute boundaries on the same clock as narration.
                // Summing separately truncated 600 Hz durations shortened the
                // six-scene 59.96 s fixture by 3.33 ms and caused -11841.
                let outputEnd = ProjectCompositionTime.fromSeconds(scheduled.projectEnd)
                let outputDuration = outputEnd - cursor
                track.scaleTimeRange(
                    CMTimeRange(
                        start: cursor,
                        duration: sourceRange.duration
                    ),
                    toDuration: outputDuration
                )
                if scheduled.clip.kind == .video,
                   let sourceAudioTrack = audioSource,
                   let audioTrack,
                   let sourceAudioTimeRange = audioRange {
                    let audioSourceRange = CMTimeRangeGetIntersection(
                        sourceRange,
                        otherRange: sourceAudioTimeRange
                    )
                    guard audioSourceRange.duration > .zero else {
                        cursor = cursor + outputDuration
                        continue
                    }
                    let sourceOffset = CMTimeGetSeconds(
                        audioSourceRange.start - sourceRange.start
                    )
                    let destination = ProjectCompositionTime.fromSeconds(
                        scheduled.projectStart + sourceOffset / scheduled.clip.playbackRate
                    )
                    try audioTrack.insertTimeRange(
                        audioSourceRange,
                        of: sourceAudioTrack,
                        at: destination
                    )
                    let audioEnd = min(outputEnd, ProjectCompositionTime.fromSeconds(
                        scheduled.projectStart
                            + (sourceOffset + audioSourceRange.duration.seconds) / scheduled.clip.playbackRate
                    ))
                    let audioOutputDuration = audioEnd - destination
                    audioTrack.scaleTimeRange(
                        CMTimeRange(
                            start: destination,
                            duration: audioSourceRange.duration
                        ),
                        toDuration: audioOutputDuration
                    )
                }
                cursor = cursor + outputDuration
            }
        }

        return VideoTimelineComposition(
            asset: composition,
            track: track,
            audioTrack: audioTrack,
            duration: cursor
        )
    }

    private static func sourceRange(
        for clip: VideoClip,
        mediaStartTime: Double
    ) -> CMTimeRange {
        switch clip.kind {
        case .video:
            let start = ProjectCompositionTime.fromSeconds(mediaStartTime + clip.sourceStart)
            let end = ProjectCompositionTime.fromSeconds(mediaStartTime + clip.sourceEnd)
            return CMTimeRange(
                start: start,
                duration: end - start
            )
        case .freeze, .image:
            return CMTimeRange(
                start: CMTime(
                    seconds: mediaStartTime + clip.sourceStart,
                    preferredTimescale: 600
                ),
                duration: CMTime(value: 1, timescale: 600)
            )
        }
    }

    /// Inserts a stretched source frame behind a full-screen title or CTA card.
    private static func insertStillFrame(
        at sourceTime: Double,
        endTime: Double,
        sourceTrack: AVAssetTrack,
        compositionTrack: AVMutableCompositionTrack,
        cursor: inout CMTime,
        sourceStart: Double,
        sourceDuration: Double
    ) throws {
        let safeTime = min(
            max(sourceTime, sourceStart),
            max(
                sourceStart + sourceDuration - 1.0 / 600,
                sourceStart
            )
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
        let outputDuration = ProjectCompositionTime.fromSeconds(endTime) - cursor
        compositionTrack.scaleTimeRange(
            CMTimeRange(start: cursor, duration: sourceRange.duration),
            toDuration: outputDuration
        )
        cursor = cursor + outputDuration
    }
}
