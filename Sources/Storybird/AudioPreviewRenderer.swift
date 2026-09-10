import AVFoundation
import Foundation
import StorybirdCore

struct AudioPreviewResult: Codable, Sendable {
    let path: String
    let startTime: Double
    let duration: Double
    let peak: Double
    let waveform: [Double]
}

enum AudioPreviewRenderer {
    /// Renders a selected mix range to a new local float WAV. The shared
    /// composition applies the same source trims, overlaps, gain and fades as MP4.
    static func render(
        project: DemoProject, sourceURL: URL, startTime: Double, duration: Double
    ) async throws -> AudioPreviewResult {
        try VideoProjectValidator.validate(project)
        guard startTime.isFinite, duration.isFinite, startTime >= 0, duration > 0,
              startTime + duration <= project.timelineDuration else {
            throw AgentEditError.invalidField("preview_range")
        }
        let built = try await EditedVideoAssetBuilder.build(project: project, sourceURL: sourceURL)
        let tracks = try await built.asset.loadTracks(withMediaType: .audio)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-audio-preview-\(UUID().uuidString).wav")
        do {
            try write(
                asset: built.asset, tracks: tracks, mix: built.audioMix,
                startTime: startTime, duration: duration, destination: destination
            )
            let summary = try ProjectAudioFiles.inspect(destination)
            return AudioPreviewResult(
                path: destination.path, startTime: startTime,
                duration: summary.duration, peak: summary.peak, waveform: summary.waveform
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies decoded mix samples while explicitly retaining timestamp gaps.
    /// Float output preserves peaks above unity for gain inspection by an agent.
    static func write(
        asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?,
        startTime: Double, duration: Double, destination: URL, gain: Double = 1
    ) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let frames = Int64((duration * rate).rounded())
        guard frames > 0 else { throw AgentEditError.invalidField("duration") }
        var cursor: Int64 = 0
        if !tracks.isEmpty {
            let reader = try AVAssetReader(asset: asset)
            AmplifiedAudioFiles.retainLeases(from: asset, on: reader)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 48_000),
                duration: CMTime(seconds: duration, preferredTimescale: 48_000)
            )
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = mix
            guard reader.canAdd(output) else { throw LayeredVideoExportError.cannotReadVideo }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? LayeredVideoExportError.cannotReadVideo }
            defer { reader.cancelReading() }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard timestamp.isFinite, let data = CMSampleBufferGetDataBuffer(sample) else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                let sampleStart = Int64(((timestamp - startTime) * rate).rounded())
                let gapEnd = min(frames, max(0, sampleStart))
                try silence(file, format: format, frames: max(0, gapEnd - cursor))
                cursor = max(cursor, gapEnd)
                let count = CMSampleBufferGetNumSamples(sample)
                let skip = max(0, cursor - sampleStart)
                let amount = min(Int64(count) - skip, frames - cursor)
                guard amount > 0 else { continue }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(amount)) else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                buffer.frameLength = AVAudioFrameCount(amount)
                let destinationBytes = buffer.mutableAudioBufferList.pointee.mBuffers.mData!
                let byteCount = Int(amount) * 8
                guard CMBlockBufferCopyDataBytes(data, atOffset: Int(skip) * 8, dataLength: byteCount, destination: destinationBytes) == noErr else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                if gain != 1 {
                    let samples = destinationBytes.assumingMemoryBound(to: Float.self)
                    for index in 0..<(Int(amount) * 2) {
                        let value = Double(samples[index]) * gain
                        guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                            throw LayeredVideoExportError.recordingMetadataMismatch
                        }
                        samples[index] = Float(value)
                    }
                }
                try file.write(from: buffer)
                cursor += amount
            }
            guard reader.status == .completed else {
                throw reader.error ?? LayeredVideoExportError.cannotReadVideo
            }
        }
        try silence(file, format: format, frames: frames - cursor)
    }

    /// Writes bounded zero buffers so silent sections retain exact duration.
    private static func silence(_ file: AVAudioFile, format: AVAudioFormat, frames: Int64) throws {
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(8_192, remaining))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let audio = buffer.mutableAudioBufferList.pointee.mBuffers
            memset(audio.mData!, 0, Int(audio.mDataByteSize))
            try file.write(from: buffer)
            remaining -= Int64(count)
        }
    }
}
