import MCP
import StorybirdCore

extension StorybirdMCPService {
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
        return [
            Tool(name: "storybird_list_voice_models", title: "List voice models",
                 description: "List the supported 1.7B and 0.6B Base 8-bit models, persistent selection, estimated download sizes and local preparation states. Does not download.",
                 inputSchema: objectSchema(),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_get_voice_model", title: "Get voice model status",
                 description: "Read not_prepared, preparing, ready or failed state and any failure message. Poll after preparing until ready or failed. Does not download.",
                 inputSchema: objectSchema(properties: model, required: ["model_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_select_voice_model", title: "Select voice model",
                 description: "Persist the model used for new speech generation and regeneration. Does not download, alter completed audio or change project revision. A different selection is rejected during voice work.",
                 inputSchema: objectSchema(properties: model, required: ["model_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_prepare_voice_model", title: "Prepare voice model",
                 description: "Start runtime installation/model download for this model without an additional approval. Return immediately; poll storybird_get_voice_model until ready or failed. Repeating a preparing/ready model does not start another download. Preserves other models, profiles and audio. No microphone access.",
                 inputSchema: objectSchema(properties: model, required: ["model_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)),
        ]
    }
}
