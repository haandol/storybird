@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import StorybirdCore

enum LayeredVideoExportError: LocalizedError {
    case missingVideoTrack
    case cannotReadVideo
    case cannotCreateWriter
    case invalidDestination
    case recordingMetadataMismatch
    case incompleteClickCue([UUID])
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The project recording has no video track."
        case .cannotReadVideo:
            return "Storybird could not read the project recording."
        case .cannotCreateWriter:
            return "Storybird could not create the exported MP4."
        case .invalidDestination:
            return "The exported video cannot replace the original recording."
        case .recordingMetadataMismatch:
            return "The project timeline does not match the original recording."
        case let .incompleteClickCue(ids):
            let values = ids.map(\.uuidString).joined(separator: ", ")
            return "Complete the description and subtitle for Click Cues: \(values)."
        case let .exportFailed(message):
            return "Storybird could not export the video: \(message)"
        }
    }
}

actor LayeredVideoExporter {
    struct PreviewFrame: Sendable {
        let pngData: Data
        let projectTime: Double
    }

    private struct AudioEncodingConfiguration {
        let readerSettings: [String: Any]
        let writerSettings: [String: Any]
        let formatDescription: CMAudioFormatDescription
        let sampleRate: Int32
        let bytesPerFrame: Int
    }

    private let imageContext = CIContext(
        options: [.cacheIntermediates: false]
    )

    /// Burns the validated project timeline into a temporary H.264 MP4 before replacing the destination.
    func export(
        project: DemoProject,
        sourceURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try Self.validateForExport(project)
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
            != destinationURL.resolvingSymlinksInPath().standardizedFileURL
        else {
            throw LayeredVideoExportError.invalidDestination
        }
        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let temporaryURL = parent.appendingPathComponent(
            ".storybird-export-\(UUID().uuidString).mp4"
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await sourceAsset.loadTracks(
            withMediaType: .video
        ).first else {
            throw LayeredVideoExportError.missingVideoTrack
        }
        let audioSourceAsset = try await AmplifiedAudioFiles.sourceAsset(
            asset: sourceAsset, url: sourceURL, gain: project.sourceAudioMuted ? 1 : project.sourceAudioVolume
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
        let sourceDuration = try await sourceAsset.load(.duration)
        let sourceVideoTimeRange = try await sourceTrack.load(.timeRange)
        let durationSeconds = CMTimeGetSeconds(
            sourceVideoTimeRange.duration
        )
        let mediaStartTime = CMTimeGetSeconds(
            sourceVideoTimeRange.start
        )
        guard let recording = project.recording,
              durationSeconds.isFinite,
              abs(durationSeconds - recording.duration) <= 0.1,
              mediaStartTime.isFinite,
              abs(
                  mediaStartTime - (recording.mediaStartTime ?? 0)
              ) <= 0.1,
              project.clicks.allSatisfy({
                  $0.sourceTime <= durationSeconds + 0.001
              }),
              project.subtitles.allSatisfy({
                  $0.endTime <= project.timelineDuration + 0.001
              })
        else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        guard !project.clips.isEmpty else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        let usesOriginalTrack =
            project.clips.count == 1
                && project.clips[0].kind == .video
                && abs(project.clips[0].sourceStart) <= 0.001
                && abs(project.clips[0].sourceEnd - durationSeconds) <= 0.001
                && abs(project.clips[0].playbackRate - 1) <= 0.001
                && abs(mediaStartTime) <= 0.001
                && abs(
                    CMTimeGetSeconds(sourceDuration) - durationSeconds
                ) <= 0.001
                && !project.effects.contains(where: \.isFullScreenCard)
                && project.narrations.isEmpty
                && project.sourceAudioVolume == 1 && !project.sourceAudioMuted
        let asset: AVAsset
        let videoTrack: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let audioMix: AVAudioMix?
        let duration: CMTime
        if usesOriginalTrack {
            asset = sourceAsset
            videoTrack = sourceTrack
            audioTracks = sourceAudioTrack.map { [$0] } ?? []
            audioMix = nil
            duration = sourceDuration
        } else {
            let timeline = try VideoTimelineCompositionBuilder.build(
                project: project,
                sourceTrack: sourceTrack,
                sourceAudioTrack: sourceAudioTrack,
                sourceAudioTimeRange: sourceAudioTimeRange
            )
            AmplifiedAudioFiles.retainLeases(from: audioSourceAsset, on: timeline.asset)
            asset = timeline.asset
            videoTrack = timeline.track
            let audio = try await NarrationCompositionBuilder.addNarrations(
                project: project,
                assetsDirectory: sourceURL.deletingLastPathComponent(),
                composition: timeline.asset,
                sourceAudioTrack: timeline.audioTrack
            )
            audioTracks = audio.tracks
            audioMix = audio.audioMix
            duration = timeline.duration
        }
        let videoComposition = try await makeVideoComposition(
            project: project,
            track: videoTrack,
            duration: duration,
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )

        let reader = try AVAssetReader(asset: asset)
        AmplifiedAudioFiles.retainLeases(from: asset, on: reader)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
            ]
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        reader.add(output)

        let writer = try AVAssetWriter(
            outputURL: temporaryURL,
            fileType: .mp4
        )
        let width = Int(videoComposition.renderSize.width.rounded())
        let height = Int(videoComposition.renderSize.height.rounded())
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        // Preserve the chosen rational output cadence in encoded timestamps.
        input.mediaTimeScale = videoComposition.frameDuration.timescale
        guard writer.canAdd(input) else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        writer.add(input)
        let audioOutput: AVAssetReaderAudioMixOutput?
        let audioInput: AVAssetWriterInput?
        let audioConfig: AudioEncodingConfiguration?
        if !audioTracks.isEmpty {
            let configuration = try makeAudioConfiguration()
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: configuration.readerSettings
            )
            output.audioMix = audioMix
            guard reader.canAdd(output) else {
                throw LayeredVideoExportError.cannotReadVideo
            }
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: configuration.writerSettings
            )
            guard writer.canAdd(input) else {
                throw LayeredVideoExportError.cannotCreateWriter
            }
            writer.add(input)
            audioOutput = output
            audioInput = input
            audioConfig = configuration
        } else {
            audioOutput = nil
            audioInput = nil
            audioConfig = nil
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error
                ?? reader.error
                ?? LayeredVideoExportError.cannotCreateWriter
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await appendMedia(
                videoOutput: output,
                reader: reader,
                videoInput: input,
                audioOutput: audioOutput,
                audioInput: audioInput,
                audioConfiguration: audioConfig,
                adaptor: adaptor,
                writer: writer,
                project: project,
                duration: duration,
                frameDuration: videoComposition.frameDuration,
                progress: progress
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        writer.endSession(atSourceTime: duration)
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error
                ?? LayeredVideoExportError.exportFailed(
                    "The video writer did not finish."
                )
        }
        try installCompletedFile(
            temporaryURL,
            at: destinationURL,
            fileManager: fileManager
        )
        progress(1)
        return destinationURL
    }

    /// Rejects invalid and incomplete projects before an export job or output file is created.
    nonisolated static func validateForExport(
        _ project: DemoProject
    ) throws {
        try VideoProjectValidator.validate(project)
        guard !project.clips.isEmpty else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        let incomplete = project.clicks.filter { !$0.isComplete }.map(\.id)
        guard incomplete.isEmpty else {
            throw LayeredVideoExportError.incompleteClickCue(incomplete)
        }
    }

    /// Renders one read-only project-resolution PNG for external MCP inspection.
    func previewPNG(
        project: DemoProject,
        sourceURL: URL,
        projectTime: Double
    ) async throws -> Data {
        try await previewFrame(
            project: project,
            sourceURL: sourceURL,
            projectTime: projectTime
        ).pngData
    }

    /// Carries the decoder's selected frame time into both overlay rendering and
    /// MCP metadata. Still segments have many project instants for one source frame.
    func previewFrame(
        project: DemoProject,
        sourceURL: URL,
        projectTime: Double
    ) async throws -> PreviewFrame {
        try VideoProjectValidator.validate(project)
        guard projectTime.isFinite,
              projectTime >= 0,
              projectTime < project.timelineDuration
        else {
            throw LayeredVideoExportError.recordingMetadataMismatch
        }
        let sourceAsset = AVURLAsset(url: sourceURL)
        guard let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw LayeredVideoExportError.missingVideoTrack
        }
        // The same edit schedule as export makes actualTime a PROJECT timestamp,
        // including offsets, repeated clips, speed changes, freezes and cards.
        let timeline = try VideoTimelineCompositionBuilder.build(
            project: project,
            sourceTrack: sourceTrack
        )
        let composition = try await makeVideoComposition(
            project: project,
            track: timeline.track,
            duration: timeline.duration,
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        let generator = AVAssetImageGenerator(asset: timeline.asset)
        generator.videoComposition = composition
        // Default tolerances permit distant keyframes, which cannot establish
        // either source identity or overlay timing near an edit boundary.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let requestedFrame = VideoFrameCadence.frameTime(
            at: projectTime,
            frameDuration: composition.frameDuration
        )
        let generated = try await generator.image(at: requestedFrame)
        let image = generated.image
        let renderTime = generated.actualTime
        guard renderTime.isNumeric, renderTime >= .zero,
              renderTime.seconds < project.timelineDuration else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let frame = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let composed = FrameOverlayRenderer.compositeFrameOverlays(
            project: project,
            over: CIImage(cgImage: image),
            at: renderTime,
            frame: frame
        )
        guard let cgImage = imageContext.createCGImage(composed, from: frame),
              let context = CGContext(
                  data: nil,
                  width: cgImage.width,
                  height: cgImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        context.draw(cgImage, in: frame)
        guard let finalImage = context.makeImage() else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        CGImageDestinationAddImage(destination, finalImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        return PreviewFrame(
            pngData: data as Data,
            projectTime: renderTime.seconds
        )
    }

    /// Interleaves composed video and optional narration with writer backpressure so
    /// either media failure cancels the single atomic MP4 result.
    private func appendMedia(
        videoOutput: AVAssetReaderVideoCompositionOutput,
        reader: AVAssetReader,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderAudioMixOutput?,
        audioInput: AVAssetWriterInput?,
        audioConfiguration: AudioEncodingConfiguration?,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        project: DemoProject,
        duration: CMTime,
        frameDuration: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let totalSeconds = max(CMTimeGetSeconds(duration), 0.001)
        var videoFinished = false
        var audioSourceFinished = audioOutput == nil
        var audioFinished = audioOutput == nil
        var pendingAudioSample: CMSampleBuffer?
        var audioCursor = CMTime.zero
        var videoCursor = CMTime.zero
        var currentVideoSample: CMSampleBuffer?
        var nextVideoSample: CMSampleBuffer?
        var videoStarted = false

        while !videoFinished || !audioFinished {
            try Task.checkCancellation()
            var appendedSample = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if videoCursor < duration {
                    if !videoStarted {
                        currentVideoSample = nextVideoFrame(from: videoOutput)
                        nextVideoSample = nextVideoFrame(from: videoOutput)
                        videoStarted = true
                    }
                    while let next = nextVideoSample,
                          CMSampleBufferGetPresentationTimeStamp(next) <= videoCursor {
                        currentVideoSample = next
                        nextVideoSample = nextVideoFrame(from: videoOutput)
                    }
                    guard let sample = currentVideoSample else {
                        throw reader.error ?? LayeredVideoExportError.cannotReadVideo
                    }
                    // A freeze or long VFR interval may contain one source sample.
                    // Hold video pixels but render layers on every output tick.
                    try appendVideoSample(
                        sample,
                        at: videoCursor,
                        to: adaptor,
                        writer: writer,
                        project: project
                    )
                    let seconds = videoCursor.seconds
                    if seconds.isFinite {
                        progress(min(max(seconds / totalSeconds, 0), 1))
                    }
                    videoCursor = videoCursor + frameDuration
                    appendedSample = true
                } else {
                    // Observe late decoding failures before publishing the output.
                    while videoOutput.copyNextSampleBuffer() != nil {}
                    videoFinished = true
                    videoInput.markAsFinished()
                }
            }
            if !audioFinished,
               let audioOutput,
               let audioInput,
               let audioConfiguration,
               audioInput.isReadyForMoreMediaData {
                if pendingAudioSample == nil, !audioSourceFinished {
                    pendingAudioSample =
                        audioOutput.copyNextSampleBuffer()
                    if pendingAudioSample == nil {
                        audioSourceFinished = true
                    }
                }
                let target = min(
                    pendingAudioSample.map(
                        CMSampleBufferGetPresentationTimeStamp
                    ) ?? duration,
                    duration
                )
                if audioCursor < target {
                    let result = try appendSilenceChunk(
                        from: audioCursor,
                        to: target,
                        configuration: audioConfiguration,
                        input: audioInput,
                        writer: writer
                    )
                    audioCursor = result.endTime
                    appendedSample = result.didAppend
                } else if let sample = pendingAudioSample {
                    guard audioInput.append(sample) else {
                        throw writer.error
                            ?? LayeredVideoExportError.exportFailed(
                                "The encoder rejected the narration track."
                            )
                    }
                    let declaredDuration = CMSampleBufferGetDuration(sample)
                    let sampleDuration =
                        declaredDuration.isValid
                            ? declaredDuration
                            : CMTime(
                                value: CMTimeValue(
                                    CMSampleBufferGetNumSamples(sample)
                                ),
                                timescale: audioConfiguration.sampleRate
                            )
                    audioCursor = max(
                        audioCursor,
                        CMSampleBufferGetPresentationTimeStamp(sample)
                            + sampleDuration
                    )
                    pendingAudioSample = nil
                    appendedSample = true
                } else if audioSourceFinished,
                          audioCursor >= duration {
                    audioFinished = true
                    audioInput.markAsFinished()
                }
            }
            if !appendedSample {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        guard reader.status == .completed else {
            throw reader.error
                ?? LayeredVideoExportError.exportFailed(
                    "The source reader stopped before completion."
                )
        }
    }

    /// Reader outputs can include end/empty-edit marker buffers. They are not
    /// video frames and must not become the held image or block lookahead.
    private func nextVideoFrame(
        from output: AVAssetReaderVideoCompositionOutput
    ) -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetPresentationTimeStamp(sample).isNumeric,
                  CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            return sample
        }
        return nil
    }

    /// Renders and appends one output tick, including repeated source pixels,
    /// on the same project clock as the optional narration track.
    private func appendVideoSample(
        _ sample: CMSampleBuffer,
        at timestamp: CMTime,
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        project: DemoProject
    ) throws {
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
              let pool = adaptor.pixelBufferPool
        else {
            throw LayeredVideoExportError.exportFailed(
                "The composed frame has no writable pixel buffer."
            )
        }
        var writableBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &writableBuffer
        ) == kCVReturnSuccess,
            let writableBuffer
        else {
            throw LayeredVideoExportError.exportFailed(
                "Storybird could not allocate an export frame."
            )
        }
        let frameBounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(writableBuffer),
            height: CVPixelBufferGetHeight(writableBuffer)
        )
        let imageWithText = FrameOverlayRenderer.compositeFrameOverlays(
            project: project,
            over: CIImage(cvPixelBuffer: sourceBuffer),
            at: timestamp,
            frame: frameBounds
        )
        imageContext.render(
            imageWithText,
            to: writableBuffer,
            bounds: frameBounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        guard adaptor.append(
            writableBuffer,
            withPresentationTime: timestamp
        ) else {
            throw writer.error
                ?? LayeredVideoExportError.exportFailed(
                    "The encoder rejected a composed frame."
                )
        }
    }

    /// Chooses one fixed PCM reader format and matching AAC writer settings so
    /// generated silence and decoded narration share one sample representation.
    private func makeAudioConfiguration() throws -> AudioEncodingConfiguration {
        // A stable stereo mix preserves stereo content regardless of which
        // mono TTS layer or primary audio track appears first.
        let sampleRate: Int32 = 48_000
        let channelCount = 2
        let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags:
                kLinearPCMFormatFlagIsSignedInteger
                    | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
            let formatDescription
        else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        return AudioEncodingConfiguration(
            readerSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            writerSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey:
                    channelCount == 1 ? 96_000 : 128_000,
            ],
            formatDescription: formatDescription,
            sampleRate: sampleRate,
            bytesPerFrame: bytesPerFrame
        )
    }

    /// Appends at most one bounded PCM silence chunk, allowing video and audio
    /// backpressure to make progress together while filling narration gaps.
    private func appendSilenceChunk(
        from start: CMTime,
        to end: CMTime,
        configuration: AudioEncodingConfiguration,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws -> (endTime: CMTime, didAppend: Bool) {
        let remainingSeconds = CMTimeGetSeconds(end - start)
        let availableFrames = Int(
            floor(remainingSeconds * Double(configuration.sampleRate))
        )
        guard availableFrames > 0 else {
            return (end, false)
        }
        let frameCount = min(availableFrames, 4_096)
        let dataLength = frameCount * configuration.bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
            let blockBuffer,
            CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            ) == kCMBlockBufferNoErr
        else {
            throw LayeredVideoExportError.cannotCreateWriter
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: 1,
                timescale: configuration.sampleRate
            ),
            presentationTimeStamp: start,
            decodeTimeStamp: .invalid
        )
        var sampleSize = configuration.bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: configuration.formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
            let sampleBuffer,
            input.append(sampleBuffer)
        else {
            throw writer.error
                ?? LayeredVideoExportError.exportFailed(
                    "The encoder rejected generated narration silence."
                )
        }
        let chunkDuration = CMTime(
            value: CMTimeValue(frameCount),
            timescale: configuration.sampleRate
        )
        return (start + chunkDuration, true)
    }

    /// Builds one composition whose video pixels and overlay layers share the same zero-based clock.
    private func makeVideoComposition(
        project: DemoProject,
        track: AVAssetTrack,
        duration: CMTime,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack
    ) async throws -> AVMutableVideoComposition {
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let transformedRect = CGRect(
            origin: .zero,
            size: naturalSize
        ).applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw LayeredVideoExportError.cannotReadVideo
        }

        var normalizedTransform = preferredTransform
        normalizedTransform.tx -= transformedRect.minX
        normalizedTransform.ty -= transformedRect.minY

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: track
        )
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = try await VideoFrameCadence.frameDuration(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            project: project
        )

        return composition
    }

    /// Keeps the existing raster test seam while delegating pixel composition.
    static func makeTextImage(
        _ text: String,
        fontSize: CGFloat,
        size: CGSize,
        foregroundHex: String = "#FFFFFF"
    ) -> CGImage? {
        FrameOverlayRenderer.makeTextImage(
            text,
            fontSize: fontSize,
            size: size,
            foregroundHex: foregroundHex
        )
    }

    private enum FrameOverlayRenderer {
    /// Applies content camera motion before adding content-linked and screen-fixed overlays.
    static func compositeFrameOverlays(
        project: DemoProject,
        over source: CIImage,
        at presentationTime: CMTime,
        frame: CGRect
    ) -> CIImage {
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let time = CMTimeGetSeconds(presentationTime)
        guard time.isFinite else { return source }
        let camera = VideoOverlayPresentation.camera(
            in: project,
            at: time
        )
        var result = applyCamera(camera, to: source, frame: frame)

        if let spotlight = project.effects.compactMap({
            if case let .spotlight(value) = $0,
               value.startTime <= time,
               time <= value.endTime {
                return value
            }
            return nil
        }).first,
            let mask = makeSpotlightImage(
                spotlight,
                frame: frame
            ) {
            result = CIImage(cgImage: mask).composited(over: result)
        }

        for click in project.clicks where
            click.indicator.startTime <= time
                && time <= click.indicator.endTime {
            let presentation = VideoOverlayPresentation.clickRing(
                for: click,
                at: time,
                camera: camera
            )
            let center = VideoOverlayLayout.clickPoint(
                x: presentation.point.x,
                y: presentation.point.y,
                in: frame,
                axis: .bottomUp
            )
            let diameter = metrics.clickRingDiameter
                * click.indicator.size
                * CGFloat(camera.scale)
                * CGFloat(presentation.diameterScale)
            if let ring = makeRingImage(
                size: CGSize(width: diameter, height: diameter),
                color: color(
                    hex: click.indicator.colorHex,
                    opacity: click.indicator.opacity
                        * presentation.opacityScale
                )
            ) {
                result = CIImage(cgImage: ring)
                    .transformed(
                        by: CGAffineTransform(
                            translationX: center.x - diameter / 2,
                            y: center.y - diameter / 2
                        )
                    )
                    .composited(over: result)
            }
        }

        for click in project.clicks where
            !click.caption.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && click.description.startTime <= time
                && time <= click.description.endTime {
            let transformed = VideoOverlayPresentation.descriptionPoint(
                for: click,
                camera: camera
            )
            let fontSize = VideoOverlayPresentation.fontSize(
                style: click.description.style,
                metrics: metrics,
                contentScale: camera.scale
            )
            let geometry = labelGeometry(
                text: click.caption,
                fontSize: fontSize,
                maximumWidth: min(
                    metrics.captionMaximumWidth,
                    frame.width - metrics.edgeInset * 2
                ),
                lineLimit: 3,
                metrics: metrics
            )
            let fit = VideoOverlayLayout.captionFitScale(
                labelSize: geometry.containerSize,
                in: frame,
                metrics: metrics
            )
            let origin = VideoOverlayLayout.captionOrigin(
                labelSize: CGSize(
                    width: geometry.containerSize.width * fit,
                    height: geometry.containerSize.height * fit
                ),
                x: transformed.x,
                y: transformed.y,
                in: frame,
                axis: .bottomUp,
                metrics: metrics
            )
            // Fit the entire measured caption, including padding, as the native
            // canvas does. Scaling one composed label preserves its line breaks.
            let caption = compositeLabel(
                click.caption,
                fontSize: fontSize,
                origin: .zero,
                geometry: geometry,
                style: click.description.style,
                over: CIImage.empty()
            )
            result = caption
                .cropped(to: CGRect(origin: .zero, size: geometry.containerSize))
                .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                .composited(over: result)
        }

        for click in project.clicks where
            click.cueSubtitle.startTime <= time
                && time <= click.cueSubtitle.endTime
                && !click.cueSubtitle.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
            result = compositeSubtitleText(
                click.cueSubtitle.text,
                style: click.cueSubtitle.style,
                position: click.cueSubtitle.position,
                over: result,
                frame: frame,
                metrics: metrics
            )
        }

        for subtitle in project.subtitles where
            subtitle.startTime <= time
                && time <= subtitle.endTime
                && !subtitle.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
            result = compositeSubtitleText(
                subtitle.text,
                style: subtitle.style,
                position: subtitle.position,
                over: result,
                frame: frame,
                metrics: metrics
            )
        }

        for effect in project.effects where
            effect.startTime <= time && time <= effect.endTime {
            switch effect {
            case let .title(value):
                result = compositeCard(
                    title: value.title,
                    secondary: value.subtitle,
                    style: value.style,
                    over: result,
                    frame: frame
                )
            case let .cta(value):
                result = compositeCard(
                    title: value.title,
                    secondary: value.buttonLabel,
                    style: value.style,
                    over: result,
                    frame: frame
                )
            case .spotlight, .panZoom:
                break
            }
        }

        if project.theme.showsBranding {
            let size = CGSize(
                width: min(180 * metrics.scale, frame.width / 2),
                height: 18 * metrics.scale
            )
            result = compositeTextRaster(
                "Made with Storybird",
                fontSize: 12 * metrics.scale,
                in: CGRect(
                    x: frame.width - size.width - metrics.subtitleInset,
                    y: 10 * metrics.scale,
                    width: size.width,
                    height: size.height
                ),
                over: result
            )
        }
        return result
    }

    private static func applyCamera(
        _ camera: VideoCameraPresentation,
        to source: CIImage,
        frame: CGRect
    ) -> CIImage {
        guard abs(camera.scale - 1) > 0.0001
                || abs(camera.x - 0.5) > 0.0001
                || abs(camera.y - 0.5) > 0.0001
        else {
            return source
        }
        let center = CGPoint(
            x: CGFloat(camera.x) * frame.width,
            y: (1 - CGFloat(camera.y)) * frame.height
        )
        let transform = CGAffineTransform(
            translationX: frame.midX,
            y: frame.midY
        )
        .scaledBy(
            x: CGFloat(camera.scale),
            y: CGFloat(camera.scale)
        )
        .translatedBy(x: -center.x, y: -center.y)
        return source.transformed(by: transform).cropped(to: frame)
    }

    private static func compositeSubtitleText(
        _ text: String,
        style: TextOverlayStyle,
        position: SubtitlePosition,
        over source: CIImage,
        frame: CGRect,
        metrics: VideoOverlayMetrics
    ) -> CIImage {
        let fontSize = VideoOverlayPresentation.fontSize(
            style: style,
            metrics: metrics
        )
        let geometry = labelGeometry(
            text: text,
            fontSize: fontSize,
            maximumWidth: min(
                metrics.subtitleMaximumWidth,
                frame.width - metrics.subtitleInset * 2
            ),
            lineLimit: 3,
            metrics: metrics
        )
        let origin = CGPoint(
            x: (frame.width - geometry.containerSize.width) / 2,
            y: position == .top
                ? frame.height
                    - geometry.containerSize.height
                    - metrics.subtitleInset
                : metrics.subtitleInset
        )
        return compositeLabel(
            text,
            fontSize: fontSize,
            origin: origin,
            geometry: geometry,
            style: style,
            over: source
        )
    }

    private static func compositeLabel(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint,
        geometry: (containerSize: CGSize, textRect: CGRect),
        style: TextOverlayStyle,
        over source: CIImage
    ) -> CIImage {
        let background = CIImage(
            color: CIColor(
                cgColor: color(
                    hex: style.backgroundHex,
                    opacity: style.backgroundOpacity
                )
            )
        ).cropped(
            to: CGRect(origin: origin, size: geometry.containerSize)
        )
        let withBackground = background.composited(over: source)
        return compositeTextRaster(
            text,
            fontSize: fontSize,
            in: geometry.textRect.offsetBy(
                dx: origin.x,
                dy: origin.y
            ),
            foregroundHex: style.foregroundHex,
            over: withBackground
        )
    }

    private static func compositeCard(
        title: String,
        secondary: String,
        style: TextOverlayStyle,
        over source: CIImage,
        frame: CGRect
    ) -> CIImage {
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let background = CIImage(
            color: CIColor(
                cgColor: color(
                    hex: style.backgroundHex,
                    opacity: style.backgroundOpacity
                )
            )
        ).cropped(to: frame)
        var result = background.composited(over: source)
        result = compositeTextRaster(
            title,
            fontSize: VideoOverlayPresentation.cardTitleFontSize(
                style: style,
                metrics: metrics
            ),
            in: CGRect(
                x: frame.width * 0.15,
                y: frame.height * 0.48,
                width: frame.width * 0.7,
                height: frame.height * 0.18
            ),
            foregroundHex: style.foregroundHex,
            over: result
        )
        if !secondary.isEmpty {
            let labelRect = CGRect(
                x: frame.width * 0.25,
                y: frame.height * 0.31,
                width: frame.width * 0.5,
                height: frame.height * 0.14
            )
            let labelBackground = CIImage(
                color: CIColor(
                    cgColor: color(
                        hex: style.foregroundHex,
                        opacity: 0.15
                    )
                )
            ).cropped(to: labelRect)
            result = labelBackground.composited(over: result)
            result = compositeTextRaster(
                secondary,
                fontSize:
                    VideoOverlayPresentation.cardSecondaryFontSize(
                        style: style,
                        metrics: metrics
                    ),
                in: CGRect(
                    x: frame.width * 0.25,
                    y: frame.height * 0.33,
                    width: frame.width * 0.5,
                    height: frame.height * 0.1
                ),
                foregroundHex: style.foregroundHex,
                over: result
            )
        }
        return result
    }

    private static func makeRingImage(
        size: CGSize,
        color: CGColor
    ) -> CGImage? {
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setStrokeColor(color)
        context.setFillColor(color.copy(alpha: 0.18) ?? color)
        let lineWidth = max(size.width * 0.08, 2)
        context.setLineWidth(lineWidth)
        let rect = CGRect(
            x: lineWidth / 2,
            y: lineWidth / 2,
            width: size.width - lineWidth,
            height: size.height - lineWidth
        )
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
        return context.makeImage()
    }

    private static func makeSpotlightImage(
        _ effect: SpotlightEffect,
        frame: CGRect
    ) -> CGImage? {
        let width = max(Int(ceil(frame.width)), 1)
        let height = max(Int(ceil(frame.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 0, alpha: effect.dimOpacity))
        context.fill(frame)
        context.setBlendMode(.clear)
        context.fill(
            CGRect(
                x: effect.x * frame.width,
                y: (1 - effect.y - effect.height) * frame.height,
                width: effect.width * frame.width,
                height: effect.height * frame.height
            )
        )
        return context.makeImage()
    }

    private static func labelGeometry(
        text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineLimit: Int,
        metrics: VideoOverlayMetrics
    ) -> (containerSize: CGSize, textRect: CGRect) {
        let contentWidth = max(
            maximumWidth - metrics.horizontalPadding * 2,
            1
        )
        let textSize = measureText(
            text,
            fontSize: fontSize,
            maximumWidth: contentWidth,
            lineLimit: lineLimit
        )
        let containerSize = CGSize(
            width: min(
                textSize.width + metrics.horizontalPadding * 2,
                maximumWidth
            ),
            height: textSize.height + metrics.verticalPadding * 2
        )
        return (
            containerSize,
            CGRect(
                x: metrics.horizontalPadding,
                y: metrics.verticalPadding,
                width: max(
                    containerSize.width - metrics.horizontalPadding * 2,
                    1
                ),
                height: max(
                    containerSize.height - metrics.verticalPadding * 2,
                    1
                )
            )
        )
    }

    private static func compositeTextRaster(
        _ text: String,
        fontSize: CGFloat,
        in rect: CGRect,
        foregroundHex: String = "#FFFFFF",
        over source: CIImage
    ) -> CIImage {
        guard let image = makeTextImage(
            text,
            fontSize: fontSize,
            size: rect.size,
            foregroundHex: foregroundHex
        ) else {
            return source
        }
        let overlay = CIImage(cgImage: image)
            .transformed(
                by: CGAffineTransform(
                    scaleX: 0.5,
                    y: 0.5
                )
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: rect.minX,
                    y: rect.minY
                )
            )
        return overlay.composited(over: source)
    }

    /// Rasterizes Core Text before video composition so glyphs use the same reliable layer path as backgrounds.
    static func makeTextImage(
        _ text: String,
        fontSize: CGFloat,
        size: CGSize,
        foregroundHex: String = "#FFFFFF"
    ) -> CGImage? {
        let scale: CGFloat = 2
        let width = max(Int(ceil(size.width * scale)), 1)
        let height = max(Int(ceil(size.height * scale)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraphStyle: CTParagraphStyle = withUnsafePointer(
            to: &alignment
        ) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                var settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: lineBreakPointer
                    ),
                ]
                return CTParagraphStyleCreate(
                    &settings,
                    settings.count
                )
            }
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName
                    as NSAttributedString.Key: color(
                        hex: foregroundHex,
                        opacity: 1
                    ),
                kCTParagraphStyleAttributeName
                    as NSAttributedString.Key: paragraphStyle,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed
        )
        let path = CGPath(
            rect: CGRect(origin: .zero, size: size),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// Measures Core Text within the same width and line-height ceiling used by the output layer.
    private static func measureText(
        _ text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineLimit: Int
    ) -> CGSize {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(
            width: min(ceil(suggested.width), maximumWidth),
            height: min(
                ceil(suggested.height),
                ceil(fontSize * 1.35 * CGFloat(lineLimit))
            )
        )
    }

    /// Parses the persisted six-digit color without allowing invalid project text into Core Animation.
    private static func color(
        hex: String,
        opacity: Double
    ) -> CGColor {
        let cleaned = hex.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16)
        else {
            return CGColor(
                red: 0.067,
                green: 0.075,
                blue: 0.102,
                alpha: min(max(opacity, 0), 1)
            )
        }
        return CGColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: min(max(opacity, 0), 1)
        )
    }
    }

    /// Replaces an approved destination only after the new video is complete.
    private func installCompletedFile(
        _ temporaryURL: URL,
        at destinationURL: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
        }
    }
}
