@preconcurrency import AVFoundation
import AVFAudio
import Foundation
import StorybirdCore

struct ProjectAudioComposition {
    let tracks: [AVAssetTrack]
    let formatTrack: AVAssetTrack?
    let audioMix: AVAudioMix?
}

enum NarrationCompositionBuilder {
    /// Adds non-overlapping project-owned narration WAVs to the shared composition
    /// and returns one mix used identically by preview and export.
    static func addNarrations(
        project: DemoProject,
        assetsDirectory: URL,
        composition: AVMutableComposition,
        sourceAudioTrack: AVMutableCompositionTrack?,
        sourceFormatTrack: AVAssetTrack?
    ) async throws -> ProjectAudioComposition {
        var tracks: [AVAssetTrack] = []
        if let sourceAudioTrack {
            tracks.append(sourceAudioTrack)
        }
        guard !project.narrations.isEmpty else {
            return ProjectAudioComposition(
                tracks: tracks,
                formatTrack: sourceFormatTrack,
                audioMix: nil
            )
        }
        guard let narrationTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let mixParameters = AVMutableAudioMixInputParameters(
            track: narrationTrack
        )
        let silenceURL = assetsDirectory.appendingPathComponent(
            ".storybird-silence.wav"
        )
        try ensureSilenceFile(at: silenceURL)
        let silenceAsset = AVURLAsset(url: silenceURL)
        guard let silenceTrack = try await silenceAsset.loadTracks(
            withMediaType: .audio
        ).first else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        var firstFormatTrack: AVAssetTrack?
        var narrationCursor = CMTime.zero
        for narration in project.narrations.sorted(
            by: { $0.startTime < $1.startTime }
        ) {
            let url = assetsDirectory.appendingPathComponent(
                narration.filename
            )
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(
                withMediaType: .audio
            ).first else {
                throw LayeredVideoExportError.cannotReadVideo
            }
            firstFormatTrack = firstFormatTrack ?? source
            let available = CMTimeGetSeconds(
                try await source.load(.timeRange).duration
            )
            guard available + 0.05 >= narration.duration else {
                throw LayeredVideoExportError.recordingMetadataMismatch
            }
            let destination = CMTime(
                seconds: narration.startTime,
                preferredTimescale: 600
            )
            let duration = CMTime(
                seconds: narration.duration,
                preferredTimescale: 600
            )
            if destination > narrationCursor {
                try insertSilence(
                    from: narrationCursor,
                    to: destination,
                    source: silenceTrack,
                    destination: narrationTrack
                )
            }
            try narrationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: destination
            )
            mixParameters.setVolume(
                Float(narration.volume),
                at: destination
            )
            mixParameters.setVolume(
                1,
                at: destination + duration
            )
            narrationCursor = destination + duration
        }
        let projectEnd = CMTime(
            seconds: project.timelineDuration,
            preferredTimescale: 600
        )
        if projectEnd > narrationCursor {
            try insertSilence(
                from: narrationCursor,
                to: projectEnd,
                source: silenceTrack,
                destination: narrationTrack
            )
        }
        tracks.append(narrationTrack)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [mixParameters]
        return ProjectAudioComposition(
            tracks: tracks,
            formatTrack: sourceFormatTrack ?? firstFormatTrack,
            audioMix: mix
        )
    }

    /// Creates one reusable second of real PCM silence so AVFoundation preserves
    /// narration gaps instead of collapsing empty edit ranges.
    private static func ensureSilenceFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 24_000,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 24_000
        ) else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        buffer.frameLength = 24_000
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: 24_000)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
    }

    /// Fills an arbitrary project-time gap by repeating bounded ranges from the
    /// one-second silence source.
    private static func insertSilence(
        from start: CMTime,
        to end: CMTime,
        source: AVAssetTrack,
        destination: AVMutableCompositionTrack
    ) throws {
        var cursor = start
        while cursor < end {
            let remaining = end - cursor
            let chunk = min(
                CMTime(seconds: 1, preferredTimescale: 24_000),
                remaining
            )
            try destination.insertTimeRange(
                CMTimeRange(start: .zero, duration: chunk),
                of: source,
                at: cursor
            )
            cursor = cursor + chunk
        }
    }
}
