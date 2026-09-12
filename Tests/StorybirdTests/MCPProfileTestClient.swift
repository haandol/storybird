import MCP
import StorybirdMCPKit

/// Runs the same behavioral expectations through either advertised wire form.
/// This caller-side map is intentionally independent of the production router.
struct MCPProfileTestClient {
    let client: Client
    let profile: StorybirdMCPToolProfile

    static let routes: [(legacy: String, compact: String, selector: String, value: String)] = [
        ("split_clip", "edit_clip", "action", "split"),
        ("trim_clip", "edit_clip", "action", "trim"),
        ("delete_clip", "edit_clip", "action", "delete"),
        ("move_clip", "edit_clip", "action", "move"),
        ("set_clip_speed", "edit_clip", "action", "set_speed"),
        ("insert_freeze", "edit_clip", "action", "insert_freeze"),
        ("create_click", "edit_click", "action", "create"),
        ("update_click", "edit_click", "action", "update"),
        ("delete_click", "edit_click", "action", "delete"),
        ("upsert_subtitle", "edit_subtitle", "action", "upsert"),
        ("delete_subtitle", "edit_subtitle", "action", "delete"),
        ("create_spotlight", "create_visual_effect", "kind", "spotlight"),
        ("create_pan_zoom", "create_visual_effect", "kind", "pan_zoom"),
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

    /// Reads the real connection's catalog without synthesizing tool definitions.
    func listTools() async throws -> (tools: [Tool], nextCursor: String?) {
        try await client.listTools()
    }

    /// Encodes a behavioral fixture in the chosen profile and calls the real MCP client.
    func callTool(name: String, arguments: [String: Value]) async throws -> (content: [Tool.Content], isError: Bool?) {
        guard profile == .compact,
              let route = Self.routes.first(where: { "storybird_" + $0.legacy == name }) else {
            return try await client.callTool(name: name, arguments: arguments)
        }
        var input = arguments
        var outer: [String: Value] = [route.selector: .string(route.value)]
        for key in ["project_id", "expected_revision"] {
            outer[key] = input.removeValue(forKey: key)
        }
        if route.legacy == "delete_narration" {
            input["layer_id"] = input.removeValue(forKey: "narration_id")
        }
        outer["input"] = .object(input)
        return try await client.callTool(name: "storybird_" + route.compact, arguments: outer)
    }
}
