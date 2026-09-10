import Foundation

/// A complete, reusable project-owned sound. Registering an asset does not
/// place it on the timeline or change the project's edit revision.
public struct ProjectAudioAsset: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case generated, imported, recorded
    }

    public var id: UUID
    public var filename: String
    public var name: String
    public var duration: Double
    public var origin: Origin
    public var voiceProfileID: UUID?
    public var text: String
    public var language: String

    /// Keeps synthesis metadata only for generated speech; ordinary recordings
    /// need neither a cloned-voice profile nor a transcript.
    public init(
        id: UUID = UUID(), filename: String, name: String, duration: Double,
        origin: Origin, voiceProfileID: UUID? = nil, text: String = "",
        language: String = "korean"
    ) {
        self.id = id
        self.filename = filename
        self.name = name
        self.duration = duration
        self.origin = origin
        self.voiceProfileID = voiceProfileID
        self.text = text
        self.language = language
    }
}

extension DemoProject {
    /// Includes legacy narration assets without migrating or rewriting their
    /// media. Multiple layers sharing a file expose one stable asset identity.
    public var availableAudioAssets: [ProjectAudioAsset] {
        var result = audioAssets
        for layer in narrations where !result.contains(where: { $0.filename == layer.filename }) {
            result.append(ProjectAudioAsset(
                id: layer.assetID, filename: layer.filename, name: layer.name,
                duration: layer.sourceDuration, origin: layer.voiceProfileID == nil ? .imported : .generated,
                voiceProfileID: layer.voiceProfileID, text: layer.text, language: layer.language
            ))
        }
        return result
    }
}
