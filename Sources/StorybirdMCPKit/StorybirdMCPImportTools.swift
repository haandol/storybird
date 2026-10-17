import MCP

extension StorybirdMCPService {
    /// Advertises app-owned path imports separately from revisioned timeline
    /// edits. Stable request keys support retries without repeated file selection.
    static var importTools: [Tool] {
        let common: [String: Value] = [
            "path": .object(["type": "string", "description": "Absolute local file path readable by Storybird. No URLs, shell expansion or file picker."]),
            "idempotency_key": .object(["type": "string", "description": "Nonblank request key, retained in this library. Same key and arguments replay the existing job; different arguments conflict."]),
        ]
        let job: [String: Value] = ["job_id": .object(["type": "string"])]
        return [
            Tool(name: "storybird_import_video", title: "Import a local video",
                 description: "Start importing a local MP4/MOV into a new independent project without native approval. Return job_id; poll storybird_get_import. Preserves the source and one primary audio track.",
                 inputSchema: objectSchema(properties: common, required: ["path", "idempotency_key"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_import_audio", title: "Import local project audio",
                 description: "Start importing a local WAV/MP3/M4A into an existing project without native approval. Register a reusable asset without changing revision or playback. Poll until completed, then place with storybird_place_audio_asset and a fresh revision.",
                 inputSchema: objectSchema(properties: common.merging([
                    "project_id": .object(["type": "string"]),
                 ]) { _, new in new }, required: ["path", "project_id", "idempotency_key"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_import_media", title: "Add project video or image media",
                 description: "Copy a local MP4/MOV or PNG/JPEG into an existing video project as a reusable source. Create the first video project with import_video or recording. Registration does not change revision or playback. Poll get_import; a completed image returns dimensions without a duration. Then place the asset with a fresh revision.",
                 inputSchema: objectSchema(properties: common.merging(["project_id": .object(["type": "string"])]) { _, new in new },
                    required: ["path", "project_id", "idempotency_key"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_list_media_assets", title: "List reusable project visuals",
                 description: "Read original video and registered video/image IDs, names, dimensions, source durations and audio metadata. A nil audio field on older recordings means unknown, not silent.",
                 inputSchema: objectSchema(properties: ["project_id": .object(["type": "string"])], required: ["project_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_place_media_asset", title: "Place an owned visual source",
                 description: "Insert an owned video/image at a zero-based clip insertion index. Images require a positive duration; videos use source_start/source_end and playback_rate (default full source, 1x). Source assets remain reusable. Validates the whole timeline and commits one revision/undo.",
                 inputSchema: objectSchema(properties: [
                    "project_id": .object(["type": "string"]), "expected_revision": .object(["type": "integer", "minimum": 0]),
                    "asset_id": .object(["type": "string"]), "destination_index": .object(["type": "integer", "minimum": 0]),
                    "duration": .object(["type": "number", "exclusiveMinimum": 0]),
                    "source_start": .object(["type": "number", "minimum": 0]),
                    "source_end": .object(["type": "number", "exclusiveMinimum": 0]),
                    "playback_rate": .object(["type": "number", "minimum": 0.25, "maximum": 4]),
                 ], required: ["project_id", "expected_revision", "asset_id", "destination_index"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_get_import", title: "Get media import status",
                 description: "Read importing/completed/failed/cancelled state. Only completed jobs expose result metadata. Jobs survive reconnect/restart in their selected library; interrupted work never automatically restarts.",
                 inputSchema: objectSchema(properties: job, required: ["job_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_cancel_import", title: "Cancel media import",
                 description: "Request cancellation of an active import. Poll until terminal; already completed/failed/cancelled jobs remain unchanged. A new attempt requires a new idempotency_key.",
                 inputSchema: objectSchema(properties: job, required: ["job_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        ]
    }
}
