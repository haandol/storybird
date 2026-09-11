import Foundation
import StorybirdCore

struct VoiceModelPreferences {
    private let defaults: UserDefaults
    private let key = "storybird.voiceModel"

    /// Uses app preferences in production and an isolated domain in tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Missing or unrecognized preferences retain the existing 1.7B default.
    var selected: VoiceModel {
        defaults.string(forKey: key).flatMap(VoiceModel.init(rawValue:)) ?? .base1_7B
    }

    /// Persists only a supported model after the store has checked busy state.
    func save(_ model: VoiceModel) {
        defaults.set(model.rawValue, forKey: key)
    }
}

/// UI and MCP expose the same model identity, readiness and failure information.
struct VoiceModelSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let repositoryID: String
    let quantizationBits: Int
    let estimatedDownloadBytes: Int64
    let selected: Bool
    let state: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, selected, state, error
        case repositoryID = "repository_id"
        case quantizationBits = "quantization_bits"
        case estimatedDownloadBytes = "estimated_download_bytes"
    }
}
