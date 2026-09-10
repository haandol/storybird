@preconcurrency import AVFoundation
import StorybirdCore

enum VideoFrameCadence {
    /// Choose the output frame covering a requested project time. Keep rational
    /// CMTime arithmetic so 1/60 does not become an earlier 600-tick approximation.
    static func frameTime(at seconds: Double, frameDuration: CMTime) -> CMTime {
        let tick = floor(seconds / frameDuration.seconds + 1e-9)
        return CMTimeMultiplyByFloat64(frameDuration, multiplier: tick)
    }

    /// A source frame is the maximum allowed timing error, even at slow playback.
    /// Faster clips need a finer output grid to preserve their source frames.
    /// Also usable by the native player's overlay observation interval.
    static func frameDuration(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        project: DemoProject
    ) async throws -> CMTime {
        let metadata = try await sourceTrack.load(.minFrameDuration)
        let minimum = try sourceFrameDuration(metadata: metadata) {
            try measuredFrameDuration(sourceAsset: sourceAsset, sourceTrack: sourceTrack)
        }
        let fastest = max(1, project.clips.filter { $0.kind == .video }.map(\.playbackRate).max() ?? 1)
        // Float64 multiplication rounds 1/60 * 0.5 to 0.008333334.
        // Repeated ticks then fall just before exact cut boundaries. A ratio
        // retains 1/120 exactly (and preserves fractional source frame rates).
        let rate = CMTime(seconds: fastest, preferredTimescale: 100_000_000)
        return CMTimeMultiplyByRatio(minimum, multiplier: rate.timescale, divisor: Int32(rate.value))
    }

    /// Missing frame metadata uses measured samples exactly once. A valid
    /// duration avoids the fallback read, while read failures remain failures.
    static func sourceFrameDuration(metadata: CMTime, measuring: () throws -> CMTime) rethrows -> CMTime {
        if metadata.isNumeric && metadata > .zero { return metadata }
        return try measuring()
    }

    /// Derives the tightest real frame bound from sample durations and ordered
    /// timestamps, ignoring codec markers and zero-length duplicate timestamps.
    static func measuredFrameDuration(sourceAsset: AVAsset, sourceTrack: AVAssetTrack) throws -> CMTime {
        let reader = try AVAssetReader(asset: sourceAsset)
        let output = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? LayeredVideoExportError.cannotReadVideo
        }
        var times: [CMTime] = []
        var durations: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isNumeric, CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(time)
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isNumeric && duration > .zero { durations.append(duration) }
        }
        guard reader.status == .completed else {
            throw reader.error ?? LayeredVideoExportError.cannotReadVideo
        }
        times.sort()
        for (left, right) in zip(times, times.dropFirst()) where right > left {
            durations.append(right - left)
        }
        guard let measured = durations.min() else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        return measured
    }
}
