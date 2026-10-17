import AVFoundation
import CoreImage
import Foundation
import StorybirdCore

struct VideoMediaSource {
    let asset: AVAsset
    let track: AVAssetTrack
    let audioAsset: AVAsset
    let audioTrack: AVAssetTrack?
    let audioRange: CMTimeRange?
    let geometry: MediaSourceGeometry
}

struct MediaSourceGeometry: Sendable {
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let mediaStartTime: Double
    let duration: Double
}

enum VideoMediaSources {
    /// Loads only referenced visuals plus the original cadence reference.
    /// Track ranges and display dimensions must still match the owned metadata.
    static func load(project: DemoProject, sourceURL: URL, audio: Bool) async throws -> [UUID: VideoMediaSource] {
        try VideoProjectValidator.validate(project)
        let used = Set(project.clips.compactMap(\.mediaAssetID)).union([project.id])
        var sources: [UUID: VideoMediaSource] = [:]
        for media in project.availableMediaAssets where media.kind == .video && used.contains(media.id) {
            let url = media.id == project.id ? sourceURL : sourceURL.deletingLastPathComponent().appendingPathComponent(media.filename)
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LayeredVideoExportError.missingVideoTrack
            }
            let range = try await track.load(.timeRange)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let display = CGRect(origin: .zero, size: size).applying(transform)
            // Older primary recordings can describe a content interval after
            // an empty leading edit. Preserve that declared source clock.
            let timingMatches = media.id == project.id
                ? range.start.seconds <= media.mediaStartTime + 0.001
                    && CMTimeRangeGetEnd(range).seconds >= media.mediaStartTime + (media.duration ?? 0) - 0.001
                : abs(range.duration.seconds - (media.duration ?? 0)) <= 0.1
                    && abs(range.start.seconds - media.mediaStartTime) <= 0.1
            guard range.duration.seconds.isFinite, timingMatches,
                  Int(abs(display.width).rounded()) == media.width,
                  Int(abs(display.height).rounded()) == media.height else {
                throw LayeredVideoExportError.recordingMetadataMismatch
            }
            let audioAsset = audio
                ? try await AmplifiedAudioFiles.sourceAsset(asset: asset, url: url,
                    gain: project.sourceAudioMuted ? 1 : project.sourceAudioVolume)
                : asset
            let audioTrack = audio ? try await audioAsset.loadTracks(withMediaType: .audio).first : nil
            if audio, let expectedAudio = media.hasAudio, expectedAudio != (audioTrack != nil) {
                throw LocalVideoImportError.unreadableAudio
            }
            let audioRange = try await audioTrack?.load(.timeRange)
            sources[media.id] = VideoMediaSource(asset: asset, track: track, audioAsset: audioAsset,
                audioTrack: audioTrack, audioRange: audioRange,
                geometry: MediaSourceGeometry(naturalSize: size, preferredTransform: transform,
                    mediaStartTime: media.mediaStartTime, duration: media.duration ?? range.duration.seconds))
        }
        return sources
    }

    static func retainAudio(_ sources: [UUID: VideoMediaSource], on target: AnyObject) {
        for source in sources.values { AmplifiedAudioFiles.retainLeases(from: source.audioAsset, on: target) }
    }
}

/// Immutable instructions are handed from AVFoundation to the rendering queue.
/// They contain value snapshots and immutable Core Image sources, never UI state.
final class MediaCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let project: DemoProject
    let sources: [UUID: MediaSourceGeometry]
    let images: [UUID: CIImage]
    let schedule: VideoTimelineSchedule

    init(project: DemoProject, trackID: CMPersistentTrackID, duration: CMTime,
         sources: [UUID: MediaSourceGeometry], images: [UUID: CIImage]) {
        self.project = project; self.trackID = trackID; self.sources = sources; self.images = images
        schedule = VideoTimelineSchedule(project: project)
        timeRange = CMTimeRange(start: .zero, duration: duration)
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }

    func image(source: CVPixelBuffer?, at time: Double, size: CGSize) throws -> CIImage {
        let item = schedule.items.first { time >= $0.projectStart && time < $0.projectEnd } ?? schedule.items.last
        let clip: VideoClip?
        switch item {
        case let .clip(value): clip = value.clip
        case let .card(value): clip = value.sourceClip
        case nil: clip = nil
        }
        guard let clip, let media = project.mediaAsset(for: clip) else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let image: CIImage
        if media.kind == .image {
            guard let loaded = images[media.id] else { throw LayeredVideoExportError.cannotReadVideo }
            image = loaded.transformed(by: CGAffineTransform(translationX: -loaded.extent.minX, y: -loaded.extent.minY))
        } else {
            guard let source, let geometry = sources[media.id] else { throw LayeredVideoExportError.cannotReadVideo }
            let raw = CIImage(cvPixelBuffer: source)
            let natural = geometry.naturalSize
            let oriented = CGRect(origin: .zero, size: natural).applying(geometry.preferredTransform)
            var transform = geometry.preferredTransform
            transform.tx -= oriented.minX; transform.ty -= oriented.minY
            // Preferred track transforms use top-down display coordinates;
            // Core Image needs the corresponding bottom-up mapping.
            let normalized = raw.transformed(by: CGAffineTransform(scaleX: natural.width / raw.extent.width,
                                                                   y: natural.height / raw.extent.height))
            let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
            let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: abs(oriented.height))
            image = normalized.transformed(by: flipIn.concatenating(transform).concatenating(flipOut))
        }
        let rect = clip.placement.frame(source: image.extent.size, canvas: size)
        let placed = image.transformed(by: CGAffineTransform(scaleX: rect.width / image.extent.width,
                                                             y: rect.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: size.height - rect.maxY))
        let rgb = UInt64(project.canvas.backgroundHex.dropFirst(), radix: 16) ?? 0
        let background = CIImage(color: CIColor(red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255))
        return placed.composited(over: background).cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// Requests are designed for asynchronous completion. A serial queue owns GPU
/// rendering, and cancellation generations are protected independently by a lock.
final class MediaVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    private let queue = DispatchQueue(label: "storybird.media-compositor")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let pending = PendingFrame(request: request, generation: lock.withLock { generation })
        queue.async { [self] in
            guard pending.generation == lock.withLock({ generation }) else {
                pending.request.finishCancelledRequest(); return
            }
            do {
                let request = pending.request
                guard let instruction = request.videoCompositionInstruction as? MediaCompositionInstruction,
                      let buffer = request.renderContext.newPixelBuffer() else {
                    throw LayeredVideoExportError.cannotReadVideo
                }
                let image = try instruction.image(source: request.sourceFrame(byTrackID: instruction.trackID),
                    at: request.compositionTime.seconds, size: request.renderContext.size)
                context.render(image, to: buffer)
                if pending.generation == lock.withLock({ generation }) {
                    request.finish(withComposedVideoFrame: buffer)
                } else { request.finishCancelledRequest() }
            } catch { pending.request.finish(with: error) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() { lock.withLock { generation &+= 1 } }

    private final class PendingFrame: @unchecked Sendable {
        let request: AVAsynchronousVideoCompositionRequest
        let generation: UInt64
        init(request: AVAsynchronousVideoCompositionRequest, generation: UInt64) {
            self.request = request; self.generation = generation
        }
    }
}

enum MediaVideoComposition {
    /// Shares the exact base picture layout between AVPlayer, PNG inspection and
    /// MP4 export. Text/effect layers remain on the existing shared overlay path.
    static func make(project: DemoProject, track: AVAssetTrack, duration: CMTime,
                     sources: [UUID: VideoMediaSource], sourceURL: URL) async throws -> AVMutableVideoComposition {
        guard let primary = sources[project.id] else { throw LayeredVideoExportError.cannotReadVideo }
        var images: [UUID: CIImage] = [:]
        let used = Set(project.clips.compactMap(\.mediaAssetID))
        for media in project.mediaAssets where media.kind == .image && used.contains(media.id) {
            let url = sourceURL.deletingLastPathComponent().appendingPathComponent(media.filename)
            let size = try ProjectMediaFiles.imageSize(at: url)
            guard size.width == media.width, size.height == media.height else {
                throw LayeredVideoExportError.recordingMetadataMismatch
            }
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw LayeredVideoExportError.cannotReadVideo
            }
            images[media.id] = image
        }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = MediaVideoCompositor.self
        composition.renderSize = project.canvasSize
        composition.frameDuration = try await VideoFrameCadence.frameDuration(
            sourceAsset: primary.asset, sourceTrack: primary.track, project: project)
        composition.instructions = [MediaCompositionInstruction(project: project, trackID: track.trackID,
            duration: duration, sources: sources.mapValues(\.geometry), images: images)]
        return composition
    }
}
