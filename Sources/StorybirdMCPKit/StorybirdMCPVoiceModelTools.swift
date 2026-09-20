import MCP
import StorybirdCore

extension StorybirdMCPService {
    static var customVoiceProperties: [String: Value] {
        [
            "speaker": .object([
                "type": "string",
                "enum": .array(CustomVoiceSpeaker.allCases.map { .string($0.rawValue) }),
                "description": "CustomVoice preset speaker. For generation, omit voice_profile_id when using this field.",
            ]),
            "instruct": .object([
                "type": "string",
                "description": "Optional natural-language speaking style, emotion or pacing instructions for CustomVoice. Empty string clears instructions. Not supported with cloned voice profiles.",
            ]),
        ]
    }

    /// Limits model operations to the shared catalog; only preparation accesses
    /// the network, and all mutations still run through the authenticated app.
    static var voiceModelTools: [Tool] {
        let model: [String: Value] = [
            "model_id": .object([
                "type": "string",
                "enum": .array(VoiceModel.allCases.map { .string($0.rawValue) }),
                "description": "The exact model id returned by storybird_list_voice_models.",
            ]),
        ]
        let removableModel: [String: Value] = [
            "model_id": .object([
                "type": "string",
                "enum": .array(VoiceModel.manageableModels.map { .string($0.rawValue) }),
                "description": "Supported model id, or the retired qwen3-tts-0.6b-base-8bit id for status/removal only.",
            ]),
        ]
        return [
            Tool(name: "storybird_list_voice_models", title: "List voice models",
                 description: "List 1.7B Base (cloning) and 1.7B CustomVoice (preset speakers with instructions), selection, download sizes, speakers and local states. Retained 0.6B files appear for removal only. Does not download.",
                 inputSchema: objectSchema(),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_get_voice_model", title: "Get voice model status",
                 description: "Read not_prepared, preparing, ready, removing or failed state and any failure message. Poll installation until ready/failed and removal until not_prepared/failed. Does not download.",
                 inputSchema: objectSchema(properties: removableModel, required: ["model_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_select_voice_model", title: "Select voice model",
                 description: "Persist the model selection in Settings. Voice source selects the generation model: profiles use Base, preset speakers use CustomVoice; regeneration retains its saved source. Does not download or change project revision. Rejected during voice work.",
                 inputSchema: objectSchema(properties: model, required: ["model_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_prepare_voice_model", title: "Prepare voice model",
                 description: "Start runtime installation/model download for this model without an additional approval. Return immediately; poll storybird_get_voice_model until ready or failed. Repeating a preparing/ready model does not start another download. Preserves other models, profiles and audio. No microphone access.",
                 inputSchema: objectSchema(properties: model, required: ["model_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)),
            Tool(name: "storybird_remove_voice_model", title: "Remove voice model",
                 description: "Remove this model's app-owned runtime and downloaded files without additional approval. Return immediately; poll storybird_get_voice_model until not_prepared or failed. Repeated removal is safe. Reject during voice work. Preserves selection, other models, profiles, generated audio and project history. Reinstall before generating with a removed model.",
                 inputSchema: objectSchema(properties: removableModel, required: ["model_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
        ]
    }
}
