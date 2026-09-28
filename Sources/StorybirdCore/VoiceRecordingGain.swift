import Foundation

public struct VoiceRecordingGain: Equatable, Sendable {
    public static let range = 0.0...4.0
    public static let unity = try! VoiceRecordingGain(multiplier: 1)
    public let multiplier: Double

    /// Validates recording volume before it can replace live capture state;
    /// invalid values leave the caller's previous gain and audio untouched.
    public init(multiplier: Double) throws {
        guard multiplier.isFinite, Self.range.contains(multiplier) else {
            throw VoiceRecordingGainError.invalidValue
        }
        self.multiplier = multiplier
    }
}

public enum VoiceRecordingGainError: LocalizedError {
    case invalidValue

    public var errorDescription: String? {
        "Recording volume must be between 0% and 400%."
    }
}
