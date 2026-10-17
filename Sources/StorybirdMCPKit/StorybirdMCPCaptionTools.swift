import MCP

extension StorybirdMCPService {
    static var captionFileTools: [Tool] {
        [
            Tool(name: "storybird_import_subtitles", title: "Append an SRT file",
                description: "Read a local UTF-8 SRT and append independent captions on the project clock. Preserve existing captions and the source. Validate the entire import and save one revision/undo; invalid entries, stale revision or I/O failure save nothing. Cue captions remain Cue components.",
                inputSchema: objectSchema(properties: ["project_id": .object(["type": "string"]),
                    "expected_revision": .object(["type": "integer", "minimum": 0]),
                    "path": .object(["type": "string", "description": "Absolute readable local SRT path."])],
                    required: ["project_id", "expected_revision", "path"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_export_subtitles", title: "Export captions as SRT",
                description: "Explicitly export independent, cue, or both caption kinds to a new unique local SRT path. Does not edit the project or render an MP4. Sort by start/end/kind/UUID (independent before cue), round to nearest millisecond with half upward, and reject a collapsed interval or text that SRT cannot represent. Existing files remain unchanged.",
                inputSchema: objectSchema(properties: ["project_id": .object(["type": "string"]),
                    "scope": .object(["type": "string", "enum": ["independent", "cue", "both"]]),
                    "parent_directory": .object(["type": "string", "description": "Optional existing absolute output directory; defaults to temporary storage."])],
                    required: ["project_id", "scope"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        ]
    }
}
