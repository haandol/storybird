import Foundation

public enum CustomVoiceSpeaker: String, Codable, CaseIterable, Sendable {
    case vivian, serena
    case uncleFu = "uncle_fu"
    case dylan, eric, ryan, aiden
    case onoAnna = "ono_anna"
    case sohee

    public var displayName: String {
        switch self {
        case .vivian: "Vivian"
        case .serena: "Serena"
        case .uncleFu: "Uncle_Fu"
        case .dylan: "Dylan"
        case .eric: "Eric"
        case .ryan: "Ryan"
        case .aiden: "Aiden"
        case .onoAnna: "Ono_Anna"
        case .sohee: "Sohee"
        }
    }
}

/// Retains the built-in speaker and optional style instruction for regeneration.
public struct CustomVoiceOptions: Codable, Hashable, Sendable {
    public var speaker: CustomVoiceSpeaker
    public var instruct: String

    /// An empty string supplies no additional speaking-style instruction.
    public init(speaker: CustomVoiceSpeaker, instruct: String = "") {
        self.speaker = speaker
        self.instruct = instruct
    }
}
