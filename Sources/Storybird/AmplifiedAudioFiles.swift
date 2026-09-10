import AVFoundation
import Foundation
import ObjectiveC

/// A live media consumer owns the derived file. The final consumer releases
/// only this temporary derivative, never the original project audio.
final class AudioFileLease: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Amplification is rendered before AVAudioMix, whose volume ramps accept 0...1.
/// Derived files are disposable local caches; projects reference only originals.
actor AmplifiedAudioFiles {
    static let shared = AmplifiedAudioFiles()
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
        let gain: Double
    }
    private final class WeakLease {
        weak var value: AudioFileLease?
        init(_ value: AudioFileLease) { self.value = value }
    }
    private var files: [Key: WeakLease] = [:]
    private static let leaseKey: StaticString = "Storybird.AudioFileLease.owner"

    /// Uses the first original movie track, replacing only its decoded samples
    /// when amplification is needed. The cached WAV retains the source time axis.
    static func sourceAsset(asset: AVAsset, url: URL, gain: Double) async throws -> AVAsset {
        guard gain > 1, try await asset.loadTracks(withMediaType: .audio).first != nil else { return asset }
        let lease = try await shared.lease(for: url, gain: gain)
        let result = AVURLAsset(url: lease.url)
        objc_setAssociatedObject(result, leaseKey.utf8Start, [lease], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return result
    }

    /// Composition segments retain URLs, not the helper AVAsset. Transfer the
    /// lease to the final asset retained by AVPlayerItem or AVAssetReader.
    static func retainLeases(from source: AVAsset, on destination: AnyObject) {
        guard let incoming = objc_getAssociatedObject(source, leaseKey.utf8Start) as? [AudioFileLease] else { return }
        let existing = objc_getAssociatedObject(destination, leaseKey.utf8Start) as? [AudioFileLease] ?? []
        objc_setAssociatedObject(destination, leaseKey.utf8Start, existing + incoming, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Validates and caches an amplified float WAV without touching the source.
    /// Concurrent renders use unique temporary paths, so publication is atomic.
    func lease(for source: URL, gain: Double) async throws -> AudioFileLease {
        guard gain > 1, gain.isFinite else { throw LayeredVideoExportError.recordingMetadataMismatch }
        files = files.filter { $0.value.value != nil }
        var refreshedURL = source
        refreshedURL.removeAllCachedResourceValues()
        let values = try refreshedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: source, modified: values.contentModificationDate, size: values.fileSize, gain: gain)
        if let cached = files[key]?.value, FileManager.default.fileExists(atPath: cached.url.path) { return cached }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LayeredVideoExportError.cannotReadVideo
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw LayeredVideoExportError.recordingMetadataMismatch }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-amplified-\(UUID().uuidString).wav")
        do {
            try AudioPreviewRenderer.write(
                asset: asset, tracks: [track], mix: nil, startTime: 0,
                duration: duration, destination: destination, gain: gain
            )
            _ = try ProjectAudioFiles.inspect(destination)
            let lease = AudioFileLease(url: destination)
            files[key] = WeakLease(lease)
            return lease
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
