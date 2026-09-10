import Foundation

public enum VoiceLanguage: String, CaseIterable, Sendable {
    case korean, english

    public var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    public var referencePrompt: String {
        switch self {
        case .korean:
            "안녕하세요. 처음에는 조금 복잡해 보일 수 있죠? 하지만 걱정하지 마세요. 중요한 기능은 또렷하게, 사용 방법은 차분하고 자연스럽게 안내해 드리겠습니다."
        case .english:
            "Hello! Does this look a little complicated at first? Don't worry. I'll explain the important features clearly, then guide you through each step with a calm, natural voice. Let's get started."
        }
    }
}
