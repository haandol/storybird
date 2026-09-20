import Foundation

public enum VoiceModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case base1_7B = "qwen3-tts-1.7b-base-8bit"
    case base0_6B = "qwen3-tts-0.6b-base-8bit"
    case customVoice1_7B = "qwen3-tts-1.7b-customvoice-8bit"

    public static let allCases: [VoiceModel] = [.base1_7B, .customVoice1_7B]
    public static let manageableModels: [VoiceModel] = allCases + [.base0_6B]

    public var isSupported: Bool { self != .base0_6B }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .base1_7B: "Qwen3-TTS 1.7B Base 8-bit"
        case .base0_6B: "Qwen3-TTS 0.6B Base 8-bit"
        case .customVoice1_7B: "Qwen3-TTS 1.7B CustomVoice 8-bit"
        }
    }

    public var repositoryID: String {
        switch self {
        case .base1_7B: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        case .base0_6B: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        case .customVoice1_7B: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
        }
    }

    /// Sum of repository file sizes, excluding the runtime; not live progress.
    /// Base metadata checked on 2026-09-11; CustomVoice on 2026-09-20 via
    /// the public Hugging Face model API with blobs=true, revision
    /// 41d3337e8b7f2843a75841595fc14e4b9a7a4b96.
    public var estimatedDownloadBytes: Int64 {
        switch self {
        case .base1_7B: 3_104_158_788
        case .base0_6B: 1_991_299_138
        case .customVoice1_7B: 3_080_141_538
        }
    }

    /// Preserve the existing 1.7B installation without moving or redownloading it.
    public var runtimeDirectoryName: String {
        switch self {
        case .base1_7B: "VoiceRuntime"
        case .base0_6B: "VoiceRuntime-0.6B-8bit"
        case .customVoice1_7B: "VoiceRuntime-CustomVoice-1.7B-8bit"
        }
    }
}
