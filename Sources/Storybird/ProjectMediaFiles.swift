import AVFoundation
import Foundation
import ImageIO
import StorybirdCore

enum ProjectMediaFiles {
    struct Frame: Sendable {
        let image: CGImage
        let sourceTime: Double
    }
    static let imageExtensions = ["png", "jpg", "jpeg"]
    static let supportedExtensions = ["mp4", "mov"] + imageExtensions

    static func filename(assetID: UUID, fileExtension: String) -> String {
        "media-\(assetID.uuidString.lowercased()).\(fileExtension)"
    }

    /// Copies first, then inspects the owned snapshot. Images are decoded with
    /// bounded thumbnail memory while retaining their original full-size bytes.
    static func copyAndInspect(source: URL, destination: URL, assetID: UUID) async throws -> ProjectMediaAsset {
        let suffix = source.pathExtension.lowercased()
        guard supportedExtensions.contains(suffix) else { throw LocalVideoImportError.unsupportedFormat }
        let name = source.deletingPathExtension().lastPathComponent
        if !imageExtensions.contains(suffix) {
            let video = try await LocalVideoImporter.copyAndInspect(sourceURL: source, destinationURL: destination)
            return ProjectMediaAsset(id: assetID, kind: .video, filename: destination.lastPathComponent,
                name: name.isEmpty ? "Imported video" : name, width: video.width, height: video.height,
                duration: video.duration, mediaStartTime: video.mediaStartTime, hasAudio: video.hasAudio)
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached {
            try LocalMediaFile.copy(from: source, to: destination)
            try Task.checkCancellation()
            let size = try imageSize(at: destination)
            return ProjectMediaAsset(id: assetID, kind: .image, filename: destination.lastPathComponent,
                name: name.isEmpty ? "Imported image" : name, width: size.width, height: size.height,
                hasAudio: false)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// Includes EXIF orientation in the display dimensions; a multi-frame
    /// container is not silently registered as a different still image.
    static func imageSize(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) != nil else { throw LocalVideoImportError.invalidDimensions }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Source-card thumbnails and MCP source inspection share the same bounded,
    /// read-only frame path. Times are relative to the asset, not the edit clock.
    static func preview(asset: ProjectMediaAsset, url: URL, time: Double = 0) async throws -> Frame {
        guard asset.filename == url.lastPathComponent, time.isFinite, time >= 0 else {
            throw AgentEditError.invalidField("asset_id or time")
        }
        if asset.kind == .image {
            guard time == 0 else { throw AgentEditError.invalidField("time") }
            _ = try imageSize(at: url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                  ] as CFDictionary) else { throw LocalVideoImportError.invalidDimensions }
            return Frame(image: image, sourceTime: 0)
        }
        guard time < (asset.duration ?? 0) else { throw AgentEditError.invalidField("time") }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: asset.mediaStartTime + time, preferredTimescale: 60_000))
        return Frame(image: result.image, sourceTime: max(0, result.actualTime.seconds - asset.mediaStartTime))
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw LocalVideoImportError.invalidDimensions
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LocalVideoImportError.invalidDimensions }
        return data as Data
    }
}
