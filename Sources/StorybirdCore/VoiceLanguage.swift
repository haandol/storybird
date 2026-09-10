import Foundation

public enum VoiceLanguage: String, CaseIterable, Sendable {
    case korean, english

    public var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    /// Original narration examples, not a benchmarked "best" cloning passage.
    /// Keep complete, connected sentences suited to the intended speaking style.
    /// Recording guidance: https://help.aliyun.com/zh/model-studio/qwen-tts-realtime-voice-replica
    public var referencePrompt: String {
        switch self {
        case .korean:
            "지금부터 사진과 짧은 영상을 함께 편집해 보겠습니다. 먼저 어떤 장면을 넣어 볼까요? 중요한 부분은 크게 보여 주고, 자막과 목소리는 자연스럽게 맞춰 주세요."
        case .english:
            "Let's turn these photos and short clips into a video. Which scene should we choose first? Keep the key details clear, then add captions and a voice that fits the story."
        }
    }
}
