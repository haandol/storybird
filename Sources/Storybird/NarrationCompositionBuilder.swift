@preconcurrency import AVFoundation
import AVFAudio
import Foundation
import StorybirdCore

struct ProjectAudioComposition {
    let tracks: [AVAssetTrack]
    let audioMix: AVAudioMix?
}

enum NarrationCompositionBuilder {
    /// Gives every independent audio layer its own composition track so insertion
    /// never pushes overlapping speech. Preview and export consume this same mix.
    static func addNarrations(
        project: DemoProject,
        assetsDirectory: URL,
        composition: AVMutableComposition,
        sourceAudioTrack: AVMutableCompositionTrack?
    ) async throws -> ProjectAudioComposition {
        var tracks: [AVAssetTrack] = []
        var parameters: [AVAudioMixInputParameters] = []
        if let sourceAudioTrack {
            tracks.append(sourceAudioTrack)
            let sourceMix = AVMutableAudioMixInputParameters(track: sourceAudioTrack)
            let volume = Float(project.sourceAudioMuted ? 0 : project.sourceAudioVolume)
            guard volume.isFinite else { throw LayeredVideoExportError.recordingMetadataMismatch }
            sourceMix.setVolume(min(1, volume), at: .zero)
            parameters.append(sourceMix)
        }
        if !project.narrations.isEmpty {
            let silenceURL = assetsDirectory.appendingPathComponent(".storybird-silence.wav")
            try ensureSilenceFile(at: silenceURL)
            let silence = AVURLAsset(url: silenceURL)
            guard let silenceTrack = try await silence.loadTracks(withMediaType: .audio).first else {
                throw LayeredVideoExportError.cannotReadVideo
            }
            let projectEnd = CMTime(seconds: project.timelineDuration, preferredTimescale: 48_000)
            for narration in project.narrations {
                try Task.checkCancellation()
                let url = assetsDirectory.appendingPathComponent(narration.filename)
                guard url.resolvingSymlinksInPath().deletingLastPathComponent()
                    == assetsDirectory.resolvingSymlinksInPath() else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                let asset = try await AmplifiedAudioFiles.sourceAsset(
                    asset: AVURLAsset(url: url), url: url, gain: narration.isMuted ? 1 : narration.volume
                )
                AmplifiedAudioFiles.retainLeases(from: asset, on: composition)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                      let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                let range = try await source.load(.timeRange)
                guard CMTimeGetSeconds(range.duration) + 0.0001 >= narration.sourceStart + narration.duration else {
                    throw LayeredVideoExportError.recordingMetadataMismatch
                }
                let start = CMTime(seconds: narration.startTime, preferredTimescale: 48_000)
                let duration = CMTime(seconds: narration.duration, preferredTimescale: 48_000)
                let end = start + duration
                try insertSilence(from: .zero, to: start, source: silenceTrack, destination: track)
                try track.insertTimeRange(CMTimeRange(
                    start: range.start + CMTime(seconds: narration.sourceStart, preferredTimescale: 48_000),
                    duration: duration
                ), of: source, at: start)
                try insertSilence(from: end, to: projectEnd, source: silenceTrack, destination: track)
                let mix = AVMutableAudioMixInputParameters(track: track)
                let requestedVolume = Float(narration.isMuted ? 0 : narration.volume)
                guard requestedVolume.isFinite else { throw LayeredVideoExportError.recordingMetadataMismatch }
                let volume = min(1, requestedVolume)
                let envelope = narration.effectiveFadeEnvelope
                let points = envelope.breakpoints(length: narration.duration)
                mix.setVolume(0, at: .zero)
                mix.setVolume(volume * Float(envelope.gain(at: 0)), at: start)
                for (from, to) in zip(points, points.dropFirst()) {
                    mix.setVolumeRamp(
                        fromStartVolume: volume * Float(envelope.gain(at: from)),
                        toEndVolume: volume * Float(envelope.gain(at: to)),
                        timeRange: CMTimeRange(
                            start: start + CMTime(seconds: from, preferredTimescale: 48_000),
                            duration: CMTime(seconds: to - from, preferredTimescale: 48_000)
                        )
                    )
                }
                // Silence decoding can carry a resampler tail across a trim;
                // explicitly close the layer's gain at its project end.
                mix.setVolume(0, at: end)
                tracks.append(track)
                parameters.append(mix)
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return ProjectAudioComposition(tracks: tracks, audioMix: parameters.isEmpty ? nil : mix)
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
