import Foundation

public enum VoiceLanguage: String, CaseIterable, Sendable {
    case korean, english

    public var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    /// Reading-time guidance, separate from the minimum recording duration.
    public var referenceDurationDescription: String {
        "about 20 seconds"
    }

    /// Original narration examples, not a benchmarked "best" cloning passage.
    /// Keep complete, connected sentences suited to the intended speaking style.
    /// Recording guidance: https://help.aliyun.com/zh/model-studio/qwen-tts-realtime-voice-replica
    public var referencePrompt: String {
        switch self {
        case .korean:
            "안녕하세요? 오늘은 Storybird의 영상 제작 과정을 소개하겠습니다. 먼저 Timeline에서 장면을 정리하고, Preview로 흐름을 확인합니다. 가장 중요한 부분은 무엇일까요? 화면과 목소리가 자연스럽게 이어지도록 자막과 설명의 타이밍을 맞추는 것입니다. 마지막으로 Export를 눌러 발표 영상을 완성합니다."
        case .english:
            "Hello! Today, I'll show you how Storybird turns a recording into a clear presentation. What should your audience notice first? Choose the key moment, add a caption, and let the narration guide them. Notice how each step keeps the message clear. Timing matters: pause, preview the result, then export a video that's ready to share."
        }
    }
}
