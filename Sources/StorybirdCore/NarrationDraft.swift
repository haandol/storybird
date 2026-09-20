import Foundation

public enum NarrationDraftState: String, Codable, Sendable {
    case generating, ready, failed, cancelled, placed
}

public struct NarrationDraft: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var voiceProfileID: UUID?
    public var customVoice: CustomVoiceOptions?
    public var text: String
    public var language: String
    public var filename: String
    public var state: NarrationDraftState
    public var duration: Double?
    public var error: String?

    /// Rejects malformed draft metadata before any project-owned file is opened.
    public static func validate(_ drafts: [NarrationDraft]) throws {
        var ids = Set<UUID>()
        for draft in drafts {
            guard (draft.voiceProfileID != nil) != (draft.customVoice != nil) else {
                throw VideoProjectValidationError.invalidNarration(
                    draft.id, "Choose exactly one voice profile or built-in speaker."
                )
            }
            guard ids.insert(draft.id).inserted,
                  !draft.filename.contains("/"), !draft.filename.contains("\\"),
                  (draft.filename as NSString).pathExtension.lowercased() == "wav",
                  !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VideoProjectValidationError.invalidAssetFilename
            }
            if draft.state == .ready || draft.state == .placed {
                guard let duration = draft.duration, duration.isFinite, duration > 0 else {
                    throw VideoProjectValidationError.invalidRecording
                }
            }
        }
    }

    /// Keeps generation metadata separate from playable layers so a completed
    /// sentence can survive a failed placement without changing the edited clock.
    public init(
        id: UUID = UUID(),
        voiceProfileID: UUID? = nil,
        text: String,
        language: String,
        filename: String,
        state: NarrationDraftState = .generating,
        duration: Double? = nil,
        error: String? = nil,
        customVoice: CustomVoiceOptions? = nil
    ) {
        self.id = id
        self.voiceProfileID = voiceProfileID
        self.customVoice = customVoice
        self.text = text
        self.language = language
        self.filename = filename
        self.state = state
        self.duration = duration
        self.error = error
    }
}
