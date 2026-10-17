import Foundation

/// Immutable visual media owned by one project. Registration and clip placement
/// are separate, so an unused asset survives a failed edit without advancing revision.
public struct ProjectMediaAsset: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, image }
    public var id: UUID
    public var kind: Kind
    public var filename: String
    public var name: String
    public var width: Int
    public var height: Int
    public var duration: Double?
    public var mediaStartTime: Double
    public var hasAudio: Bool?

    public init(id: UUID = UUID(), kind: Kind, filename: String, name: String,
                width: Int, height: Int, duration: Double? = nil,
                mediaStartTime: Double = 0, hasAudio: Bool? = nil) {
        self.id = id; self.kind = kind; self.filename = filename; self.name = name
        self.width = width; self.height = height; self.duration = duration
        self.mediaStartTime = mediaStartTime; self.hasAudio = hasAudio
    }
}

public struct MediaPlacement: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case fit, fill }
    public var mode: Mode
    public var anchorX: Double
    public var anchorY: Double

    public init(mode: Mode = .fit, anchorX: Double = 0.5, anchorY: Double = 0.5) {
        self.mode = mode; self.anchorX = anchorX; self.anchorY = anchorY
    }

    public var isValid: Bool {
        anchorX.isFinite && anchorY.isFinite && (0...1).contains(anchorX) && (0...1).contains(anchorY)
    }

    /// Top-down content bounds; Core Image callers invert the vertical origin
    /// at their boundary instead of changing the saved normalized anchor.
    public func frame(source: CGSize, canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let xScale = canvas.width / source.width
        let yScale = canvas.height / source.height
        let scale = mode == .fit ? min(xScale, yScale) : max(xScale, yScale)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (canvas.width - size.width) * anchorX,
                      y: (canvas.height - size.height) * anchorY, width: size.width, height: size.height)
    }
}

public struct ProjectCanvas: Codable, Hashable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        case original, landscape, portrait, square
        public var title: String {
            switch self {
            case .original: "Original"
            case .landscape: "16:9 · 1920 × 1080"
            case .portrait: "9:16 · 1080 × 1920"
            case .square: "1:1 · 1080 × 1080"
            }
        }
    }
    public var preset: Preset
    public var backgroundHex: String
    public init(preset: Preset = .original, backgroundHex: String = "#000000") {
        self.preset = preset; self.backgroundHex = backgroundHex
    }
    public func size(original: CGSize) -> CGSize {
        switch preset {
        case .original: original
        case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }
}

extension DemoProject {
    /// The primary recording uses the project identity in the visual-media
    /// namespace. Legacy clips with no explicit asset ID continue to refer to it.
    public var availableMediaAssets: [ProjectMediaAsset] {
        var result: [ProjectMediaAsset] = []
        if let recording {
            result.append(ProjectMediaAsset(id: id, kind: .video, filename: recording.filename,
                name: name, width: recording.width, height: recording.height,
                duration: recording.duration, mediaStartTime: recording.mediaStartTime ?? 0,
                hasAudio: recording.hasAudio))
        }
        return result + mediaAssets
    }

    public func mediaAsset(for clip: VideoClip) -> ProjectMediaAsset? {
        availableMediaAssets.first { $0.id == (clip.mediaAssetID ?? id) }
    }

    public var canvasSize: CGSize {
        canvas.size(original: recording.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
    }
}
