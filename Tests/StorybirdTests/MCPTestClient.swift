import MCP
import XCTest

/// Encodes operation fixtures in the sole advertised compact wire form.
/// This caller-side map is intentionally independent of the production router.
struct MCPTestClient {
    let client: Client

    static let routes: [(command: String, compact: String, selector: String, value: String)] = [
        ("split_clip", "edit_clip", "action", "split"),
        ("trim_clip", "edit_clip", "action", "trim"),
        ("delete_clip", "edit_clip", "action", "delete"),
        ("move_clip", "edit_clip", "action", "move"),
        ("duplicate_clip", "edit_clip", "action", "duplicate"),
        ("set_clip_duration", "edit_clip", "action", "set_duration"),
        ("place_media_asset", "edit_clip", "action", "place_media"),
        ("set_clip_speed", "edit_clip", "action", "set_speed"),
        ("insert_freeze", "edit_clip", "action", "insert_freeze"),
        ("create_click", "edit_click", "action", "create"),
        ("update_click", "edit_click", "action", "update"),
        ("delete_click", "edit_click", "action", "delete"),
        ("upsert_subtitle", "edit_subtitle", "action", "upsert"),
        ("delete_subtitle", "edit_subtitle", "action", "delete"),
        ("create_spotlight", "create_visual_effect", "kind", "spotlight"),
        ("create_pan_zoom", "create_visual_effect", "kind", "pan_zoom"),
        ("create_mask", "create_visual_effect", "kind", "mask"),
        ("insert_title", "insert_card", "kind", "title"),
        ("insert_cta", "insert_card", "kind", "cta"),
        ("update_effect", "edit_effect", "action", "update"),
        ("delete_effect", "edit_effect", "action", "delete"),
        ("update_suggestion", "edit_suggestion", "action", "update"),
        ("apply_suggestion", "edit_suggestion", "action", "apply"),
        ("reject_suggestion", "edit_suggestion", "action", "reject"),
        ("update_audio_layer", "edit_audio_layer", "action", "update"),
        ("split_audio_layer", "edit_audio_layer", "action", "split"),
        ("duplicate_audio_layer", "edit_audio_layer", "action", "duplicate"),
        ("delete_audio_layer", "edit_audio_layer", "action", "delete"),
        ("delete_narration", "edit_audio_layer", "action", "delete"),
        ("undo_project", "edit_history", "action", "undo"),
        ("redo_project", "edit_history", "action", "redo"),
    ]

    /// Expands an advertised branch only for property assertions. Calls still use
    /// its real selector/input envelope, and missing public branches fail tests.
    static func operationTool(named name: String, in tools: [Tool]) throws -> Tool {
        if let direct = tools.first(where: { $0.name == name }) { return direct }
        let route = try XCTUnwrap(routes.first { "storybird_" + $0.command == name })
        let tool = try XCTUnwrap(tools.first { $0.name == "storybird_" + route.compact })
        let schema = try XCTUnwrap(tool.inputSchema.objectValue)
        let branch = try XCTUnwrap(schema["oneOf"]?.arrayValue?.first {
            $0.objectValue?["properties"]?.objectValue?[route.selector]?.objectValue?["const"]?.stringValue == route.value
        })
        var input = try XCTUnwrap(branch.objectValue?["properties"]?.objectValue?["input"]?.objectValue)
        let envelope = try XCTUnwrap(schema["properties"]?.objectValue).filter {
            ["project_id", "expected_revision"].contains($0.key)
        }
        input["properties"] = .object(try XCTUnwrap(input["properties"]?.objectValue).merging(envelope) { _, new in new })
        input["required"] = .array([.string("project_id"), .string("expected_revision")] + (input["required"]?.arrayValue ?? []))
        return Tool(name: tool.name, title: tool.title, description: tool.description,
                    inputSchema: .object(input), annotations: tool.annotations)
    }

    /// Reads the real connection's catalog without synthesizing tool definitions.
    func listTools() async throws -> (tools: [Tool], nextCursor: String?) {
        try await client.listTools()
    }

    /// Encodes an operation fixture in compact form and calls the real MCP client.
    func callTool(name: String, arguments: [String: Value]) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard let route = Self.routes.first(where: { "storybird_" + $0.command == name }) else {
            return try await client.callTool(name: name, arguments: arguments)
        }
        var input = arguments
        var outer: [String: Value] = [route.selector: .string(route.value)]
        for key in ["project_id", "expected_revision"] {
            outer[key] = input.removeValue(forKey: key)
        }
        if route.command == "delete_narration" {
            input["layer_id"] = input.removeValue(forKey: "narration_id")
        }
        outer["input"] = .object(input)
        return try await client.callTool(name: "storybird_" + route.compact, arguments: outer)
    }
}
