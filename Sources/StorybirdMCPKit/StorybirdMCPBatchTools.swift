import MCP
import StorybirdCore

extension StorybirdMCPService {
    /// Uses the same field definitions as the deterministic planner. Exact
    /// kind/source-specific bounds are also available in the edit context.
    static var batchTools: [Tool] {
        let id: Value = .object(["type": "string", "format": "uuid"])
        let number: Value = .object(["type": "number"])
        let index: Value = .object(["type": "integer", "minimum": 0])
        var clipFields = ProjectEditFields.clip(.video)
        for kind in [VideoClipKind.freeze, .image] {
            clipFields.merge(ProjectEditFields.clip(kind)) { old, _ in old }
        }
        let examples: [DemoEffect] = [
            .spotlight(SpotlightEffect(startTime: 0, endTime: 1, x: 0, y: 0, width: 1, height: 1)),
            .panZoom(PanZoomEffect(startTime: 0, endTime: 1, endX: 0.5, endY: 0.5, endScale: 1)),
            .title(TitleCardEffect(startTime: 0, endTime: 1, title: "Title")),
            .cta(CTACardEffect(startTime: 0, endTime: 1, title: "CTA", buttonLabel: "Continue")),
        ]
        var effectFields: [String: ProjectEditField] = [:]
        for example in examples { effectFields.merge(ProjectEditFields.effect(example)) { old, _ in old } }
        let fields: [ProjectEditTarget: [String: ProjectEditField]] = [
            .clip: clipFields, .click: ProjectEditFields.click, .subtitle: ProjectEditFields.subtitle,
            .audio: ProjectEditFields.audio, .effect: effectFields, .project: ProjectEditFields.project,
        ]
        func definition(_ field: ProjectEditField) -> Value {
            var result: [String: Value] = ["type": .string(field.type.rawValue)]
            if let value = field.minimum { result["minimum"] = .double(value) }
            if let value = field.maximum { result["maximum"] = .double(value) }
            if let value = field.exclusiveMinimum { result["exclusiveMinimum"] = .double(value) }
            if let values = field.choices { result["enum"] = .array(values.map(Value.string)) }
            if let pattern = field.pattern { result["pattern"] = .string(pattern) }
            if !field.description.isEmpty { result["description"] = .string(field.description) }
            return .object(result)
        }
        func branch(_ target: ProjectEditTarget, _ action: String, _ properties: [String: Value],
                    required: [String] = [], related: Bool = false) -> Value {
            var fields: [String: Value] = [
                "target": .object(["type": "string", "const": .string(target.rawValue)]),
                "id": id, "action": .object(["type": "string", "const": .string(action)]),
                "values": objectSchema(properties: properties, required: required),
            ]
            if related { fields["related_ids"] = .object(["type": "array", "items": id, "minItems": 1, "uniqueItems": true]) }
            return objectSchema(properties: fields,
                required: ["target", "id", "action"] + (action == "delete" ? [] : ["values"]) + (related ? ["related_ids"] : []))
        }
        var branches: [Value] = []
        for target in ProjectEditTarget.allCases {
            branches.append(branch(target, "update", (fields[target] ?? [:]).mapValues(definition)))
            if target != .project {
                branches.append(branch(target, "delete", [:]))
                let moving = target == .clip ? ["destination_index": index] : ["delta": number]
                branches.append(branch(target, "move", moving, required: Array(moving.keys)))
                let duplicating = target == .clip ? ["destination_index": index] : ["start_time": number]
                branches.append(branch(target, "duplicate", duplicating, required: Array(duplicating.keys)))
            }
        }
        branches.append(branch(.clip, "split", ["source_time": number], required: ["source_time"]))
        branches.append(branch(.clip, "split", ["clip_offset": number], required: ["clip_offset"]))
        branches.append(branch(.audio, "split", ["time": number], required: ["time"]))
        branches.append(branch(.subtitle, "split", ["time": number, "text_offset": .object(["type": "integer", "minimum": 1,
            "description": "Internal offset counted in Unicode grapheme clusters from the start of the original text."])], required: ["time", "text_offset"]))
        branches.append(branch(.subtitle, "merge", ProjectEditFields.subtitle.filter { !["start_time", "end_time"].contains($0.key) }.mapValues(definition),
            required: ["text"], related: true))
        let input = objectSchema(properties: [
            "project_id": id, "expected_revision": index,
            "edits": .object(["type": "array", "minItems": 1, "items": .object(["oneOf": .array(branches)])]),
        ], required: ["project_id", "expected_revision", "edits"])
        let semantics = "One explicit target/id/action/values object per target. Times are seconds. Structural clip/card edits precede one linked-time remap, then explicit layer edits; conflicting direct timing rejects the whole request. Unknown fields/types or duplicate targets reject everything. Read get_edit_context for this target's actual fields and source bounds. Video split uses source_time; image/freeze split uses clip_offset. Audio split uses project time. Subtitle split requires time and text_offset counted in Unicode grapheme clusters; merge requires the earliest id, adjacent related_ids and explicit combined text. Reorder indices are zero-based insertion positions after removal. Project deletion, asset registration, synthesis and file output are separate tools."
        return [
            Tool(name: "storybird_preview_edits", title: "Preview an atomic edit",
                description: "Validate and describe the complete prospective edit without saving, creating assets/jobs or changing undo. Generated IDs are provisional: use apply's generated IDs for follow-up edits. " + semantics,
                inputSchema: input, annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_apply_edits", title: "Apply an atomic edit",
                description: "Apply one complete edit through Storybird's writer as one revision and one undo. Return the resulting project, direct/derived changes and generated IDs. Failures include current_revision and a structured error. " + semantics,
                inputSchema: input, annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        ]
    }
}
