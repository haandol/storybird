import AVFoundation
import Foundation

enum LocalVideoImportError: LocalizedError {
    case unsupportedFormat
    case missingVideoTrack
    case invalidDuration
    case invalidDimensions
    case unreadableAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Choose an MP4 or QuickTime MOV file."
        case .missingVideoTrack:
            return "The selected file does not contain a readable video track."
        case .invalidDuration:
            return "The selected video must have a duration greater than zero."
        case .invalidDimensions:
            return "The selected video has invalid display dimensions."
        case .unreadableAudio:
            return "The selected video's primary audio track could not be read."
        }
    }
}

struct ImportedVideoMetadata: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let mediaStartTime: Double
}

enum LocalVideoImporter {
    /// Returns the one supported movie extension used for the project-owned copy,
    /// rejecting other local file types before project publication begins.
    static func supportedFileExtension(
        for sourceURL: URL
    ) throws -> String {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov"].contains(fileExtension) else {
            throw LocalVideoImportError.unsupportedFormat
        }
        return fileExtension
    }

    /// Copies a native-selected or MCP-supplied movie into unpublished storage,
    /// honoring cancellation before the caller atomically publishes the project.
    static func copyAndInspect(
        sourceURL: URL,
        destinationURL: URL,
        didCopyBytes: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> ImportedVideoMetadata {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try Task.checkCancellation()
        let copy = Task.detached {
            try LocalMediaFile.copy(from: sourceURL, to: destinationURL, didCopyBytes: didCopyBytes)
        }
        try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: {
            copy.cancel()
        }
        try Task.checkCancellation()
        return try await inspect(url: destinationURL)
    }

    /// Reads the copied asset's media contract so invalid video, dimensions, or
    /// narration cannot enter the local project library.
    private static func inspect(
        url: URL
    ) async throws -> ImportedVideoMetadata {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(
            withMediaType: .video
        ).first else {
            throw LocalVideoImportError.missingVideoTrack
        }
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard videoReader.canAdd(videoOutput) else { throw LocalVideoImportError.missingVideoTrack }
        videoReader.add(videoOutput)
        guard videoReader.startReading(), videoOutput.copyNextSampleBuffer() != nil,
              videoReader.status != .failed else { throw LocalVideoImportError.missingVideoTrack }
        videoReader.cancelReading()
        let videoTimeRange = try await videoTrack.load(.timeRange)
        let duration = CMTimeGetSeconds(videoTimeRange.duration)
        let mediaStartTime = CMTimeGetSeconds(videoTimeRange.start)
        guard duration.isFinite, duration > 0 else {
            throw LocalVideoImportError.invalidDuration
        }
        guard mediaStartTime.isFinite else {
            throw LocalVideoImportError.invalidDuration
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let displayRect = CGRect(
            origin: .zero,
            size: naturalSize
        ).applying(transform)
        let width = Int(abs(displayRect.width).rounded())
        let height = Int(abs(displayRect.height).rounded())
        guard width > 0, height > 0 else {
            throw LocalVideoImportError.invalidDimensions
        }
        let audioTrack = try await asset.loadTracks(
            withMediaType: .audio
        ).first
        if let audioTrack {
            let descriptions = try await audioTrack.load(
                .formatDescriptions
            )
            guard !descriptions.isEmpty else {
                throw LocalVideoImportError.unreadableAudio
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                ]
            )
            guard reader.canAdd(output) else {
                throw LocalVideoImportError.unreadableAudio
            }
            reader.add(output)
            guard reader.startReading(),
                  output.copyNextSampleBuffer() != nil,
                  reader.status != .failed
            else {
                throw LocalVideoImportError.unreadableAudio
            }
            reader.cancelReading()
        }
        return ImportedVideoMetadata(
            duration: duration,
            width: width,
            height: height,
            mediaStartTime: mediaStartTime
        )
    }
}
