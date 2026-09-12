import Foundation
import MCP

/// A connection keeps one catalog for its entire lifetime. Existing launch
/// configurations retain their original public calls unless they opt in.
public enum StorybirdMCPToolProfile: String, Sendable, CaseIterable {
    case legacy
    case compact

    /// Defaults existing launches to legacy and rejects unknown options before
    /// a server connection or app session can begin.
    public init(arguments: [String]) throws {
        if arguments.isEmpty {
            self = .legacy
        } else if arguments.count == 2, arguments[0] == "--tool-profile",
                  let profile = Self(rawValue: arguments[1]) {
            self = profile
        } else {
            throw StorybirdMCPToolInputError(
                message: "Usage: StorybirdMCP [--tool-profile legacy|compact]"
            )
        }
    }
}

struct StorybirdMCPToolInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Each branch reuses one existing tool's input contract and one app command.
/// There is no batch execution or project persistence in this adapter.
struct StorybirdMCPToolGroup: Sendable {
    struct Branch: Sendable {
        let value: String
        let toolName: String
    }

    let name: String
    let title: String
    let selector: String
    let branches: [Branch]

    /// Names a fixed group of existing app commands and its explicit selector.
    init(_ name: String, _ title: String, selector: String = "action", _ branches: [(String, String)]) {
        self.name = "storybird_" + name
        self.title = title
        self.selector = selector
        self.branches = branches.map { Branch(value: $0.0, toolName: "storybird_" + $0.1) }
    }

    static let all: [Self] = [
        .init("edit_clip", "Edit a video clip", [
            ("split", "split_clip"), ("trim", "trim_clip"), ("delete", "delete_clip"),
            ("move", "move_clip"), ("set_speed", "set_clip_speed"), ("insert_freeze", "insert_freeze"),
        ]),
        .init("edit_click", "Edit a Click Cue", [
            ("create", "create_click"), ("update", "update_click"), ("delete", "delete_click"),
        ]),
        .init("edit_subtitle", "Edit an independent subtitle", [
            ("upsert", "upsert_subtitle"), ("delete", "delete_subtitle"),
        ]),
        .init("create_visual_effect", "Create a visual effect", selector: "kind", [
            ("spotlight", "create_spotlight"), ("pan_zoom", "create_pan_zoom"),
        ]),
        .init("insert_card", "Insert a timeline card", selector: "kind", [
            ("title", "insert_title"), ("cta", "insert_cta"),
        ]),
        .init("edit_effect", "Edit or delete an effect", [
            ("update", "update_effect"), ("delete", "delete_effect"),
        ]),
        .init("edit_suggestion", "Edit, apply or reject a click suggestion", [
            ("update", "update_suggestion"), ("apply", "apply_suggestion"), ("reject", "reject_suggestion"),
        ]),
        .init("edit_audio_layer", "Edit a placed audio layer", [
            ("update", "update_audio_layer"), ("split", "split_audio_layer"),
            ("duplicate", "duplicate_audio_layer"), ("delete", "delete_audio_layer"),
        ]),
        .init("edit_history", "Undo or redo a project edit", [
            ("undo", "undo_project"), ("redo", "redo_project"),
        ]),
    ]

    static let replacedNames = Set(all.flatMap { $0.branches.map(\.toolName) })
        .union(["storybird_delete_narration"])

    private static let envelopeKeys: Set<String> = ["project_id", "expected_revision"]

    /// Reuses existing fields and bounds, including compact's explicit positive
    /// spotlight sizes. Root oneOf ties each selector to its closed input object.
    func definition(legacy: [String: Tool]) -> Tool {
        let firstSchema = legacy[branches[0].toolName]!.inputSchema.objectValue!
        let envelope = firstSchema["properties"]!.objectValue!.filter { Self.envelopeKeys.contains($0.key) }
        var schema = StorybirdMCPService.objectSchema(
            properties: envelope.merging([
                selector: .object(["type": "string", "enum": .array(branches.map { .string($0.value) })]),
                "input": .object(["type": "object", "description": "Only the fields for the selected \(selector). Use {} when none are needed."]),
            ]) { _, new in new },
            required: ["project_id", "expected_revision", selector, "input"]
        ).objectValue!
        schema["oneOf"] = .array(branches.map { branch in
            .object(["properties": .object([
                selector: .object(["const": .string(branch.value)]),
                "input": branchInput(legacy[branch.toolName]!),
            ])])
        })
        let descriptions = branches.map { branch in
            "\(branch.value): \(legacy[branch.toolName]!.description ?? "")"
        }.joined(separator: "\n")
        return Tool(
            name: name, title: title,
            description: """
            Choose \(selector) explicitly and put that operation's fields in input. \
            project_id and expected_revision stay at the top level. Executes one \
            existing app command; omitted optional fields keep their existing meaning. \
            \(descriptions)
            """,
            inputSchema: .object(schema),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        )
    }

    /// Rejects invalid branch input before returning exactly one app command,
    /// preserving the original fields and revision envelope.
    func resolve(_ arguments: [String: Value], legacy: [String: Tool]) throws -> (name: String, arguments: [String: Value]) {
        let allowed = Self.envelopeKeys.union([selector, "input"])
        if let unknown = Set(arguments.keys).subtracting(allowed).sorted().first {
            throw invalid("Unknown argument: \(unknown)")
        }
        guard let selected = arguments[selector]?.stringValue,
              let branch = branches.first(where: { $0.value == selected }) else {
            throw invalid("Expected \(selector): \(branches.map(\.value).joined(separator: ", "))")
        }
        guard let input = arguments["input"]?.objectValue else {
            throw invalid("input must be an object")
        }
        let tool = legacy[branch.toolName]!
        try Self.validate(.object(input), schema: branchInput(tool), path: "input")
        var flattened = input
        for key in Self.envelopeKeys {
            guard let value = arguments[key] else { throw invalid("Missing argument: \(key)") }
            flattened[key] = value
        }
        try Self.validate(.object(flattened), schema: tool.inputSchema, path: "arguments")
        return (branch.toolName, flattened)
    }

    /// Moves operation fields into a closed input object. Compact also exposes
    /// the app's positive spotlight dimensions without changing legacy schemas.
    private func branchInput(_ tool: Tool) -> Value {
        var schema = tool.inputSchema.objectValue!
        var properties = schema["properties"]!.objectValue!.filter { !Self.envelopeKeys.contains($0.key) }
        if ["storybird_create_spotlight", "storybird_update_effect"].contains(tool.name) {
            properties = Self.positiveSpotlightDimensions(properties)
        } else if tool.name == "storybird_update_suggestion" {
            var spotlight = properties["spotlight"]!.objectValue!
            spotlight["properties"] = .object(Self.positiveSpotlightDimensions(spotlight["properties"]!.objectValue!))
            properties["spotlight"] = .object(spotlight)
        }
        schema["properties"] = .object(properties)
        schema["required"] = .array(schema["required"]!.arrayValue!.filter {
            !Self.envelopeKeys.contains($0.stringValue!)
        })
        return .object(schema)
    }

    /// Matches the app's nonzero normalized rectangle sizes; zero never denotes
    /// a valid spotlight, including partial effect and suggestion updates.
    private static func positiveSpotlightDimensions(_ properties: [String: Value]) -> [String: Value] {
        var result = properties
        for key in ["width", "height"] {
            var field = result[key]!.objectValue!
            field.removeValue(forKey: "minimum")
            field["exclusiveMinimum"] = 0
            result[key] = .object(field)
        }
        return result
    }

    /// Returns a tool-scoped error without forwarding a request to the app.
    private func invalid(_ message: String) -> StorybirdMCPToolInputError {
        .init(message: "\(name): \(message). No changes were made.")
    }

    /// Validates the subset used by the existing editing schemas. The app still
    /// validates IDs, timing relationships, revision, persistence and undo.
    private static func validate(_ value: Value, schema: Value, path: String) throws {
        let fields = schema.objectValue!
        /// Adds the failing nested field path while keeping errors free of input values.
        func reject(_ reason: String) throws -> Never {
            throw StorybirdMCPToolInputError(message: "Invalid \(path): \(reason). No changes were made.")
        }
        switch fields["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { try reject("expected an object") }
            let properties = fields["properties"]?.objectValue ?? [:]
            if fields["additionalProperties"]?.boolValue == false,
               let unknown = Set(object.keys).subtracting(properties.keys).sorted().first {
                try reject("unknown argument \(unknown)")
            }
            for required in fields["required"]?.arrayValue ?? [] {
                let key = required.stringValue!
                guard object[key] != nil else { try reject("missing \(key)") }
            }
            for key in object.keys.sorted() {
                if let property = properties[key] {
                    try validate(object[key]!, schema: property, path: "\(path).\(key)")
                }
            }
        case "string":
            // The SDK decodes data-URL JSON strings as .data, then encodes them
            // as strings again. Match the legacy wire form rather than its enum.
            switch value {
            case .string, .data: break
            default: try reject("expected a string")
            }
        case "boolean":
            guard value.boolValue != nil else { try reject("expected a boolean") }
        case "integer", "number":
            guard let number = numericValue(value), number.isFinite else { try reject("expected a finite number") }
            if fields["type"]?.stringValue == "integer", value.intValue == nil, Int(exactly: number) == nil {
                try reject("expected an integer")
            }
            if let limit = fields["minimum"].flatMap(numericValue), number < limit { try reject("below \(limit)") }
            if let limit = fields["maximum"].flatMap(numericValue), number > limit { try reject("above \(limit)") }
            if let limit = fields["exclusiveMinimum"].flatMap(numericValue), number <= limit { try reject("must exceed \(limit)") }
        default:
            try reject("unsupported input schema")
        }
        if let allowed = fields["enum"]?.arrayValue, !allowed.contains(value) {
            try reject("expected one of \(allowed)")
        }
    }

    /// Accepts JSON numbers without treating booleans or strings as numbers.
    private static func numericValue(_ value: Value) -> Double? {
        switch value {
        case let .int(number): Double(number)
        case let .double(number): number
        default: nil
        }
    }
}
