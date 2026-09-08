import AVFAudio
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import Storybird

enum TestVideoFactory {
    static func makeToneWAV(
        at url: URL,
        duration: Double,
        frequency: Double = 440
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeTone(
            to: url,
            duration: duration,
            frequency: frequency
        )
    }

    static func makeMP3(
        at url: URL,
        duration: Double
    ) throws {
        let wav = url.deletingPathExtension()
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try makeToneWAV(at: wav, duration: duration)
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/opt/homebrew/bin/ffmpeg"
        )
        process.arguments = [
            "-y",
            "-loglevel", "error",
            "-i", wav.path,
            "-codec:a", "libmp3lame",
            url.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalVideoImportError.unreadableAudio
        }
    }

    /// Creates a deterministic one-second movie so import and export tests can prove
    /// video-only and narrated media behavior without network or external tools.
    static func makeMovie(
        at destinationURL: URL,
        fileType: AVFileType = .mp4,
        includeAudio: Bool,
        audioStart: Double = 0,
        audioDuration: Double? = nil,
        toneFrequency: Double = 440,
        duration: Double = 1
    ) async throws -> ScreenVideoRecordingResult {
        let root = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let rawVideoURL = root.appendingPathComponent(
            "raw-\(UUID().uuidString).mp4"
        )
        defer {
            try? FileManager.default.removeItem(at: rawVideoURL)
        }
        let writer = try ScreenVideoWriter(outputURL: rawVideoURL)
        let frameCount = max(Int((duration * 30).rounded()), 1)
        for frame in 0..<frameCount {
            writer.append(
                try sampleBuffer(
                    presentationTime: CMTime(
                        value: CMTimeValue(frame),
                        timescale: 30
                    )
                )
            )
        }
        let result = try await writer.finish()

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: rawVideoURL)
        let videoTrack = try await videoAsset.loadTracks(
            withMediaType: .video
        ).first
        guard let videoTrack,
              let compositionVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else {
            throw LayeredVideoExportError.missingVideoTrack
        }
        let duration = CMTime(
            seconds: result.duration,
            preferredTimescale: 600
        )
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(
            .preferredTransform
        )

        var audioURL: URL?
        if includeAudio {
            let requestedAudioDuration = audioDuration
                ?? max(result.duration - audioStart, 0)
            let generatedAudioURL = root.appendingPathComponent(
                "audio-\(UUID().uuidString).caf"
            )
            audioURL = generatedAudioURL
            try writeTone(
                to: generatedAudioURL,
                duration: requestedAudioDuration,
                frequency: toneFrequency
            )
            let audioAsset = AVURLAsset(url: generatedAudioURL)
            guard let sourceAudio = try await audioAsset.loadTracks(
                withMediaType: .audio
            ).first,
                let compositionAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else {
                throw LocalVideoImportError.unreadableAudio
            }
            try compositionAudio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(
                        seconds: requestedAudioDuration,
                        preferredTimescale: 600
                    )
                ),
                of: sourceAudio,
                at: CMTime(
                    seconds: audioStart,
                    preferredTimescale: 600
                )
            )
        }
        defer {
            if let audioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = fileType
        exporter.shouldOptimizeForNetworkUse = false
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error
                ?? LayeredVideoExportError.exportFailed(
                    "The test movie could not be created."
                )
        }
        return result
    }

    /// Creates an audio-only MP4 so import rejection can verify the mandatory
    /// readable-video-track contract.
    static func makeAudioOnlyMovie(
        at destinationURL: URL
    ) async throws {
        let root = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let audioURL = root.appendingPathComponent(
            "audio-only-\(UUID().uuidString).caf"
        )
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }
        try writeTone(to: audioURL, duration: 1, frequency: 440)
        let source = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        guard let sourceTrack = try await source.loadTracks(
            withMediaType: .audio
        ).first,
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw LocalVideoImportError.unreadableAudio
        }
        try compositionTrack.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 1, preferredTimescale: 600)
            ),
            of: sourceTrack,
            at: .zero
        )
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error
                ?? LayeredVideoExportError.cannotCreateWriter
        }
    }

    /// Decodes one time range and returns its average normalized PCM amplitude so
    /// tests can distinguish preserved narration from generated silence.
    static func averageAmplitude(
        in url: URL,
        from start: Double,
        to end: Double
    ) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(
            withMediaType: .audio
        ).first else {
            return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error
                ?? LayeredVideoExportError.cannotReadVideo
        }
        var total = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let bufferStart = CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
            guard let description =
                    CMSampleBufferGetFormatDescription(sample),
                  let stream =
                    CMAudioFormatDescriptionGetStreamBasicDescription(
                        description
                    )?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample)
            else {
                continue
            }
            let sampleRate = stream.mSampleRate
            let channels = max(Int(stream.mChannelsPerFrame), 1)
            let frameCount = CMSampleBufferGetNumSamples(sample)
            let bufferEnd = bufferStart
                + Double(frameCount) / sampleRate
            guard bufferEnd > start, bufferStart < end else {
                continue
            }
            let firstFrame = max(
                Int(floor((start - bufferStart) * sampleRate)),
                0
            )
            let lastFrame = min(
                Int(ceil((end - bufferStart) * sampleRate)),
                frameCount
            )
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            guard CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: &bytes
            ) == kCMBlockBufferNoErr else {
                throw LayeredVideoExportError.cannotReadVideo
            }
            bytes.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                for frame in firstFrame..<lastFrame {
                    for channel in 0..<channels {
                        let index = frame * channels + channel
                        guard index < values.count else { continue }
                        total += abs(Double(values[index]))
                            / Double(Int16.max)
                        count += 1
                    }
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error
                ?? LayeredVideoExportError.cannotReadVideo
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Writes deterministic PCM narration of the requested length so tests can
    /// verify timing transforms and silent gaps after AAC encoding.
    private static func writeTone(
        to url: URL,
        duration: Double,
        frequency: Double
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ) else {
            throw LocalVideoImportError.unreadableAudio
        }
        let frameCount = AVAudioFrameCount(
            max((duration * format.sampleRate).rounded(), 1)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw LocalVideoImportError.unreadableAudio
        }
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channels[channel][frame] = Float(
                        0.25 * sin(
                            2 * Double.pi * frequency
                                * Double(frame) / format.sampleRate
                        )
                    )
                }
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
    }

    /// Creates one deterministic BGRA frame accepted by the production video writer.
    private static func sampleBuffer(
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            48,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
            let pixelBuffer
        else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(
                base,
                0x44,
                CVPixelBufferGetDataSize(pixelBuffer)
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr,
            let description
        else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr,
            let sample
        else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        return sample
    }
}
