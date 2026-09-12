import Foundation
import MCP

public struct StorybirdMCPService: Sendable {
    private let client: StorybirdAppIPCClient
    private let toolProfile: StorybirdMCPToolProfile

    /// Keeps one profile for the connection, defaulting to the original public
    /// calls so existing client configurations retain their behavior.
    public init(client: StorybirdAppIPCClient = .init(), toolProfile: StorybirdMCPToolProfile = .legacy) {
        self.client = client
        self.toolProfile = toolProfile
    }

    /// Runs one local stdio MCP connection and aborts capture when it closes.
    public func run() async throws {
        let server: Server
        do {
            server = try await startServer(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            await abortActiveSession()
            throw error
        }
        await abortActiveSession()
    }

    /// Uses the same initialization compatibility boundary for stdio and tests.
    func startServer(transport: any Transport) async throws -> Server {
        let server = await makeServer()
        try await server.start(transport: StorybirdMCPTransport(transport))
        return server
    }

    /// Builds the production MCP handlers independently of transport, allowing
    /// protocol tests to exercise discovery and calls without the user's socket.
    func makeServer() async -> Server {
        let server = Server(
            name: "storybird",
            version: "0.1.7",
            title: "Storybird Video Production",
            instructions: """
            Use one selected display or window per session. Starting a session \
            shares that source with the MCP client and allows real pointer \
            movement, clicks, and scrolling while Storybird records a local \
            silent video. These tools do not authorize \
            purchases, messages, uploads, account changes, or other external \
            side effects. Keyboard input and microphone recording are not provided by MCP. \
            For prompt-to-video production, prefer storybird_start_narration_draft with text \
            and an existing voice_profile_id. Poll storybird_get_narration_draft until ready, \
            use the measured duration to edit picture length, then place the draft once \
            with storybird_place_narration_draft. Read current project revision before mutations. \
            Use storybird_get_edit_context to find project.narrations layer IDs, and \
            storybird_list_audio_assets for reusable asset IDs. Edit or duplicate audio layers, \
            audition storybird_render_audio_preview, and poll the export job to completion. \
            Audio layers can overlap; no live microphone or repeated editing approvals are needed \
            once a local model and voice profile are prepared. \
            Use storybird_list_voice_models to inspect the two Base 8-bit models, \
            storybird_select_voice_model to select one, and storybird_prepare_voice_model \
            to download and prepare it without another approval. Poll \
            storybird_get_voice_model until ready or failed before synthesizing. \
            Import local video or project audio by absolute path using storybird_import_video \
            or storybird_import_audio with a stable idempotency_key; no file picker or folder \
            approval is needed. Poll storybird_get_import until terminal. Replay the same \
            key and arguments after a lost response; use a new key for a new attempt. \
            Screen capture follows the saved recording auto-approval preference (off by default). \
            Use storybird_get_recording_auto_approval to inspect it and \
            storybird_set_recording_auto_approval with an explicit enabled boolean only when \
            the user requests that settings change. It persists across app restarts and skips \
            only Storybird's session dialog, never macOS permissions or deletion approval. \
            Project editing does not require an active screen-control session. \
            Resolve scene and layer IDs with storybird_get_edit_context, make targeted edits, \
            then inspect storybird_render_preview using its returned actual frame time and layer IDs. \
            Updating only a Cue time preserves its component windows; to move a whole Cue, \
            supply the indicator, description and subtitle windows together. \
            Use exact advertised argument names; unknown arguments are rejected without changes. \
            A ready draft survives placement failure: edit the picture or placement and reuse it. \
            Do not infer speech quality from a generated file or waveform alone.
            """ + profileInstructions,
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolDefinitions(for: toolProfile))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await callTool(parameters)
        }

        return server
    }

    /// Ends any app-owned capture without reopening the app just to clean up.
    func abortActiveSession() async {
        _ = try? await client.call(
            name: "storybird_abort_session",
            argumentsJSON: Data("{}".utf8),
            launchIfNeeded: false
        )
    }

    /// Defines the public computer-use surface and its side-effect hints.
    static var toolDefinitions: [Tool] {
        sourceTools + projectTools + layerTools + voiceTools + draftTools + audioTools + exportTools + importTools + voiceModelTools
    }

    private static let exposedTools = Dictionary(uniqueKeysWithValues: toolDefinitions.map { ($0.name, $0) })

    /// Advertises either original tools or grouped edits, never both aliases.
    static func toolDefinitions(for profile: StorybirdMCPToolProfile) -> [Tool] {
        switch profile {
        case .legacy: toolDefinitions
        case .compact:
            toolDefinitions.filter { !StorybirdMCPToolGroup.replacedNames.contains($0.name) }
                + StorybirdMCPToolGroup.all.map { $0.definition(legacy: exposedTools) }
        }
    }

    private var profileInstructions: String {
        switch toolProfile {
        case .legacy:
            "\nTool profile: legacy. Use the advertised operation-specific tools."
        case .compact:
            """
            \nTool profile: compact. Use storybird_edit_clip, storybird_edit_click, \
            storybird_edit_subtitle, storybird_edit_effect, storybird_edit_suggestion, \
            storybird_edit_audio_layer and storybird_edit_history with an explicit action. \
            storybird_create_visual_effect and storybird_insert_card use kind instead. \
            Put project_id and expected_revision at the top level and operation fields in input \
            ({} for undo/redo). One call executes one operation. Use layer_id for placed audio, \
            including generated narration; text regeneration remains storybird_update_narration. \
            Read the selected branch's required fields and units; do not mix actions' fields. \
            Pending suggestion update/reject keeps the output revision; apply edits the project. \
            After an ambiguous edit response, read current state before retrying.
            """
        }
    }

    /// Lists complete audio assets and exposes the same independent layer edits
    /// as the native editor. Microphone and voice-profile reference selection stay native.
    private static var audioTools: [Tool] {
        let project: [String: Value] = ["project_id": .object(["type": "string"])]
        let revision: [String: Value] = project.merging([
            "expected_revision": .object(["type": "integer", "minimum": 0]),
        ]) { _, new in new }
        let layer = revision.merging(["layer_id": .object(["type": "string"])]) { _, new in new }
        let number: Value = .object(["type": "number", "minimum": 0])
        let duration: Value = .object(["type": "number", "exclusiveMinimum": 0, "description": "Positive duration in seconds."])
        let timing: Value = .object(["type": "string", "enum": ["project", "scene"]])
        return [
            Tool(name: "storybird_list_audio_assets", title: "List reusable project audio",
                 description: "List complete project-owned audio assets with IDs, measured durations, peaks and waveform summaries. Generate TTS drafts with an existing voice profile, then place the ready draft once; use layer duplication for repeated speech.",
                 inputSchema: objectSchema(properties: project, required: ["project_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_place_audio_asset", title: "Place a reusable audio asset",
                 description: "Place an existing project sound at project seconds, optionally trimming its source range. Overlapping audio is mixed. Out-of-project placement fails without losing the asset.",
                 inputSchema: objectSchema(properties: revision.merging([
                    "asset_id": .object(["type": "string"]), "start_time": number,
                    "source_start": number, "duration": duration, "timing_mode": timing,
                 ]) { _, new in new }, required: ["project_id", "expected_revision", "asset_id", "start_time"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_update_audio_layer", title: "Edit one audio layer",
                 description: "Atomically edit name, project start, source trim, duration, gain (1 = original), mute and linear fade lengths in seconds. Audio layers may overlap. Omitted properties retain their values.",
                 inputSchema: objectSchema(properties: layer.merging([
                    "name": .object(["type": "string"]), "start_time": number, "source_start": number,
                    "duration": duration, "volume": number, "muted": .object(["type": "boolean"]),
                    "fade_in": number, "fade_out": number, "timing_mode": timing,
                 ]) { _, new in new }, required: ["project_id", "expected_revision", "layer_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_split_audio_layer", title: "Split an audio layer",
                 description: "Split strictly inside a layer at project seconds, preserving its full source file for undo.",
                 inputSchema: objectSchema(properties: layer.merging(["time": number]) { _, new in new }, required: ["project_id", "expected_revision", "layer_id", "time"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_duplicate_audio_layer", title: "Duplicate an audio layer",
                 description: "Reuse the same complete audio under a new layer ID, optionally at another project start time. Does not resynthesize TTS.",
                 inputSchema: objectSchema(properties: layer.merging(["start_time": number]) { _, new in new }, required: ["project_id", "expected_revision", "layer_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_delete_audio_layer", title: "Delete an audio layer",
                 description: "Remove a layer while keeping its reusable audio and undo history.",
                 inputSchema: objectSchema(properties: layer, required: ["project_id", "expected_revision", "layer_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_set_source_audio", title: "Set source movie audio gain",
                 description: "Set original movie audio volume or mute. Its timing continues to follow the edited video clips.",
                 inputSchema: objectSchema(properties: revision.merging(["volume": number, "muted": .object(["type": "boolean"])]) { _, new in new }, required: ["project_id", "expected_revision"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_render_audio_preview", title: "Render an audio mix preview",
                 description: "Render a project range to a new local WAV using the export mix. Returns path, measured duration, peak and waveform; no audio bytes. Peaks above 1 indicate gain should be reduced. File creation alone does not verify pronunciation or naturalness.",
                 inputSchema: objectSchema(properties: project.merging(["start_time": number, "duration": duration]) { _, new in new }, required: ["project_id", "start_time", "duration"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        ]
    }

    private static var voiceTools: [Tool] {
        [
            Tool(
                name: "storybird_list_voice_profiles",
                title: "List local Storybird voice profiles",
                description: "List user-created local voice profiles without returning reference audio bytes.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_generate_narration",
                title: "Generate and place speech",
                description: "Generate and place in one call using an existing profile. Prefer storybird_start_narration_draft for production: its ready audio survives a placement conflict.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "voice_profile_id": .object(["type": "string"]),
                        "text": .object(["type": "string"]),
                        "language": .object(["type": "string"]),
                        "timing_mode": .object(["type": "string", "enum": ["project", "scene"]]),
                        "start_time": .object(["type": "number", "minimum": 0]),
                    ],
                    required: [
                        "project_id",
                        "expected_revision",
                        "voice_profile_id",
                        "text",
                        "start_time",
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_update_narration",
                title: "Update or regenerate narration",
                description: "Update timing or volume, or regenerate only this narration WAV when text is supplied, against the current project revision.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "narration_id": .object(["type": "string"]),
                        "text": .object(["type": "string"]),
                        "language": .object(["type": "string"]),
                        "timing_mode": .object(["type": "string", "enum": ["project", "scene"]]),
                        "start_time": .object(["type": "number", "minimum": 0]),
                        "volume": .object(["type": "number", "minimum": 0, "description": "Gain multiplier; 1 is the original volume. No automatic normalization."]),
                    ],
                    required: [
                        "project_id",
                        "expected_revision",
                        "narration_id",
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_delete_narration",
                title: "Delete one narration layer",
                description: "Delete one narration layer while retaining its reusable WAV for undo.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "narration_id": .object(["type": "string"]),
                    ],
                    required: [
                        "project_id",
                        "expected_revision",
                        "narration_id",
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
        ]
    }

    private static var clickProperties: [String: Value] {
        var fields: [String: Value] = [
            "click_id": .object(["type": "string"]),
            "button": .object(["type": "string", "enum": ["left", "right"]]),
            "description_position": .object(["type": "string", "enum": ["automatic", "custom"]]),
            "subtitle_position": .object(["type": "string", "enum": ["top", "bottom"]]),
        ]
        for key in ["caption", "description", "subtitle", "background_hex", "indicator_color_hex",
                    "description_background_hex", "description_foreground_hex", "subtitle_background_hex", "subtitle_foreground_hex"] {
            fields[key] = .object(["type": "string"])
        }
        for key in ["time", "indicator_start_time", "indicator_end_time", "description_start_time", "description_end_time", "subtitle_start_time", "subtitle_end_time"] {
            fields[key] = .object(["type": "number", "minimum": 0])
        }
        fields["time"] = .object([
            "type": "number", "minimum": 0,
            "description": "Project seconds. On update, omitted component windows stay fixed and must contain this time. Supply all windows explicitly to move the whole Cue.",
        ])
        for key in ["x", "y", "description_x", "description_y", "indicator_opacity", "background_opacity", "description_background_opacity", "subtitle_background_opacity"] {
            fields[key] = .object(["type": "number", "minimum": 0, "maximum": 1])
        }
        fields["indicator_size"] = .object(["type": "number", "exclusiveMinimum": 0])
        for key in ["description_font_size", "subtitle_font_size"] {
            fields[key] = .object(["type": "number", "minimum": 1])
        }
        return fields
    }

    private static var layerTools: [Tool] {
        let id: Value = .object(["type": "string"])
        let time: Value = .object(["type": "number", "minimum": 0])
        let unit: Value = .object(["type": "number", "minimum": 0, "maximum": 1])
        let scale: Value = .object(["type": "number", "minimum": 1, "maximum": 3])
        let spotlight: [String: Value] = ["start_time": time, "end_time": time, "x": unit, "y": unit, "width": unit, "height": unit, "dim_opacity": unit]
        let zoom: [String: Value] = ["start_time": time, "end_time": time, "start_x": unit, "start_y": unit, "end_x": unit, "end_y": unit, "start_scale": scale, "end_scale": scale]
        let card: [String: Value] = ["title": id, "subtitle": id, "button_label": id, "duration": .object(["type": "number", "exclusiveMinimum": 0]), "after_clip_id": id]
        let style: [String: Value] = ["foreground_hex": id, "background_hex": id, "background_opacity": unit, "font_size": .object(["type": "number", "minimum": 1])]
        var effect = spotlight.merging(zoom) { _, new in new }.merging(style) { _, new in new }
        for key in ["effect_id", "title", "subtitle", "button_label"] { effect[key] = id }
        return [
            Tool(name: "storybird_get_edit_context", title: "Resolve text requests to scenes and layers",
                 description: "Read the current revision, one-based scene numbers and clip times, plus current click captions, subtitles, effects and narration. Use returned IDs for text-driven edits; Storybird does not interpret natural language.",
                 inputSchema: projectIDSchema(), annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_create_project", title: "Create an empty project",
                 description: "Create a named placeholder. Every later recording still creates a separate video project.",
                 inputSchema: objectSchema(properties: ["name": id], required: ["name"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_abort_session", title: "Discard an active recording",
                 description: "Abort the active session and discard its incomplete recording. Use stop_session to save a finished video instead.",
                 inputSchema: objectSchema(), annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)),
            layerTool("storybird_create_click", "Add a Click Cue", "Add a Cue at project time, optionally supplying its description and subtitle.", clickProperties.filter { $0.key != "click_id" }, ["time", "x", "y"]),
            layerTool("storybird_delete_click", "Delete a Click Cue", "Remove a Cue and its suggestion metadata; previously applied effects remain.", ["click_id": id], ["click_id"]),
            layerTool("storybird_delete_subtitle", "Delete a subtitle", "Remove one independent subtitle.", ["subtitle_id": id], ["subtitle_id"]),
            layerTool("storybird_create_spotlight", "Add a spotlight", "Emphasize a normalized rectangle for a time interval.", spotlight, ["start_time", "end_time", "x", "y", "width", "height"]),
            layerTool("storybird_create_pan_zoom", "Add pan and zoom", "Move and zoom the picture between normalized centers.", zoom, ["start_time", "end_time", "end_x", "end_y", "end_scale"]),
            layerTool("storybird_insert_title", "Insert a title card", "Insert at the beginning or after a nonfinal clip; later layers shift together.", card.filter { $0.key != "button_label" && $0.key != "subtitle" }, ["title", "duration"]),
            layerTool("storybird_insert_cta", "Insert a closing CTA", "Append one noninteractive closing card.", card.filter { $0.key != "after_clip_id" && $0.key != "subtitle" }, ["title", "button_label", "duration"]),
            layerTool("storybird_update_effect", "Edit effect properties", "Change only supplied properties of one effect; fields must match its type.", effect, ["effect_id"]),
            layerTool("storybird_delete_effect", "Delete an effect", "Remove a visual effect or close a title/CTA gap with linked timing changes.", ["effect_id": id], ["effect_id"]),
            layerTool("storybird_update_suggestion", "Edit a pending suggestion", "Change split time or nested spotlight/pan_zoom properties before applying.", ["suggestion_id": id, "split_time": time, "spotlight": objectSchema(properties: spotlight), "pan_zoom": objectSchema(properties: zoom)], ["suggestion_id"]),
            layerTool("storybird_apply_suggestion", "Apply a suggestion", "Apply its split and effects as one undoable project edit.", ["suggestion_id": id], ["suggestion_id"]),
            layerTool("storybird_reject_suggestion", "Reject a suggestion", "Reject a pending suggestion without changing output or edit revision.", ["suggestion_id": id], ["suggestion_id"]),
        ]
    }

    /// Uses the same revision envelope for every narrow, undoable layer edit.
    private static func layerTool(_ name: String, _ title: String, _ description: String, _ fields: [String: Value], _ required: [String]) -> Tool {
        Tool(name: name, title: title, description: description,
             inputSchema: revisionedProjectSchema(properties: fields, required: required),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false))
    }

    private static var draftTools: [Tool] {
        let project: [String: Value] = ["project_id": .object(["type": "string"])]
        let identified = project.merging(["draft_id": .object(["type": "string"])]) { _, new in new }
        return [
            Tool(name: "storybird_start_narration_draft", title: "Generate a reusable narration draft",
                 description: "Start local sentence synthesis without placing it or changing the edit revision. Poll the draft and place its measured WAV after editing the scene length.",
                 inputSchema: objectSchema(properties: project.merging([
                    "voice_profile_id": .object(["type": "string"]), "text": .object(["type": "string"]),
                    "language": .object(["type": "string"]),
                 ]) { _, new in new }, required: ["project_id", "voice_profile_id", "text"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
            Tool(name: "storybird_list_narration_drafts", title: "List narration drafts",
                 description: "List project-owned generation jobs, states, text, languages and measured durations.",
                 inputSchema: objectSchema(properties: project, required: ["project_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_get_narration_draft", title: "Get narration draft state",
                 description: "Return generating, ready, failed, cancelled or placed state. Ready drafts survive restart and timing conflicts.",
                 inputSchema: objectSchema(properties: identified, required: ["project_id", "draft_id"]),
                 annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_cancel_narration_draft", title: "Cancel or discard a narration draft",
                 description: "Cancel synthesis or discard a ready draft; never removes placed narration.",
                 inputSchema: objectSchema(properties: identified, required: ["project_id", "draft_id"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
            Tool(name: "storybird_place_narration_draft", title: "Place a ready narration draft",
                 description: "Place the existing WAV at project seconds with optional scene timing. Conflicts retain the ready draft. A draft can be placed only once.",
                 inputSchema: objectSchema(properties: identified.merging([
                    "expected_revision": .object(["type": "integer", "minimum": 0]),
                    "start_time": .object(["type": "number", "minimum": 0]),
                    "timing_mode": .object(["type": "string", "enum": ["project", "scene"]]),
                 ]) { _, new in new }, required: ["project_id", "draft_id", "expected_revision", "start_time"]),
                 annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        ]
    }

    private static var sourceTools: [Tool] {
        [
            Tool(
                name: "storybird_get_recording_auto_approval",
                title: "Get MCP recording auto-approval",
                description: "Return the saved app-wide recording auto-approval setting as {enabled: boolean}. Does not start capture.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_set_recording_auto_approval",
                title: "Set MCP recording auto-approval",
                description: """
                Change the persistent app-wide setting only when the user requests it. \
                When enabled, future authenticated MCP sessions can record their requested \
                display or window, share live frames and control the pointer without \
                Storybird's Allow dialog. Default is false. Returns {enabled: boolean}. \
                Does not start capture, resolve pending prompts or stop active sessions. \
                macOS permissions and permanent deletion approval still apply.
                """,
                inputSchema: Self.objectSchema(
                    properties: ["enabled": .object(["type": "boolean"])],
                    required: ["enabled"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_list_sources",
                title: "List Storybird capture sources",
                description: "List displays and ordinary windows available for one Storybird MCP session.",
                inputSchema: Self.objectSchema(),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            Tool(
                name: "storybird_start_session",
                title: "Start Storybird computer use",
                description: """
                Start one source session. This shares live PNG frames with the \
                MCP client, records a local silent video, and enables real \
                pointer input after Storybird's approval policy and macOS permission checks. \
                The app dialog is skipped only when recording auto-approval is enabled.
                """,
                inputSchema: Self.objectSchema(
                    properties: [
                        "source_id": .object([
                            "type": "string",
                            "description": "Source ID returned by storybird_list_sources.",
                        ]),
                        "project_name": .object([
                            "type": "string",
                            "description": "Name of the Storybird video project created at stop.",
                        ]),
                    ],
                    required: [
                        "source_id",
                        "project_name",
                    ]
                ),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ),
            Tool(
                name: "storybird_observe",
                title: "Observe the selected source",
                description: "Return the latest PNG for the active Storybird MCP source.",
                inputSchema: Self.objectSchema(),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            Tool(
                name: "storybird_move_pointer",
                title: "Move the macOS pointer",
                description: "Move the visible pointer to normalized coordinates inside the selected source.",
                inputSchema: Self.pointerSchema(
                    extraProperties: [
                        "duration_ms": .object([
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 5_000,
                            "description": "Visible movement duration in milliseconds.",
                        ]),
                    ],
                    extraRequired: []
                ),
                annotations: Self.pointerAnnotations
            ),
            Tool(
                name: "storybird_click",
                title: "Click the selected source",
                description: """
                Move to normalized coordinates and post one real left or right \
                click. A click can trigger external side effects; use the \
                client's normal user-approval policy.
                """,
                inputSchema: Self.pointerSchema(
                    extraProperties: [
                        "button": .object([
                            "type": "string",
                            "enum": ["left", "right"],
                            "description": "Mouse button; defaults to left.",
                        ]),
                    ],
                    extraRequired: []
                ),
                annotations: Self.pointerAnnotations
            ),
            Tool(
                name: "storybird_scroll",
                title: "Scroll the selected source",
                description: "Move to normalized coordinates and post one real horizontal or vertical wheel event.",
                inputSchema: Self.pointerSchema(
                    extraProperties: [
                        "delta_x": .object([
                            "type": "number",
                            "description": "Horizontal pixel wheel delta.",
                        ]),
                        "delta_y": .object([
                            "type": "number",
                            "description": "Vertical pixel wheel delta.",
                        ]),
                    ],
                    extraRequired: ["delta_x", "delta_y"]
                ),
                annotations: Self.pointerAnnotations
            ),
        ]
    }

    private static var projectTools: [Tool] {
        [
            Tool(
                name: "storybird_duplicate_project",
                title: "Duplicate a video project",
                description: "Copy a video and its narration into an independent editable project. The source revision is checked; draft jobs and undo history are not copied.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: ["name": .object(["type": "string"])],
                    required: []
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_list_projects",
                title: "List Storybird projects",
                description: "List local Storybird project metadata through the running app.",
                inputSchema: Self.objectSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_get_project",
                title: "Get a Storybird project",
                description: "Return the complete editable project model without image bytes.",
                inputSchema: Self.projectIDSchema(),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_replace_project",
                title: "Apply a complete project edit",
                description: "Validate and atomically replace every editable project property against an expected revision.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "project_json": .object(["type": "string"]),
                    ],
                    required: [
                        "project_id",
                        "expected_revision",
                        "project_json",
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_split_clip",
                title: "Split a video clip",
                description: "Split one source-backed clip at an immutable recording time and return the new revision and clip IDs.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                        "source_time": .object([
                            "type": "number",
                            "minimum": 0.0,
                        ]),
                    ],
                    required: ["clip_id", "source_time"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_trim_clip",
                title: "Trim a video clip",
                description: "Keep one source-time range from a clip and remove linked layers outside that range.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                        "source_start": .object([
                            "type": "number",
                            "minimum": 0.0,
                        ]),
                        "source_end": .object([
                            "type": "number",
                            "minimum": 0.0,
                        ]),
                    ],
                    required: ["clip_id", "source_start", "source_end"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_delete_clip",
                title: "Delete a timeline clip",
                description: "Remove one clip from the edited timeline without changing the original recording.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                    ],
                    required: ["clip_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_move_clip",
                title: "Move a timeline clip",
                description: "Move one clip to a zero-based destination index and remap its linked layers.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                        "destination": .object([
                            "type": "integer",
                            "minimum": 0,
                        ]),
                    ],
                    required: ["clip_id", "destination"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_set_clip_speed",
                title: "Set clip playback speed",
                description: "Set one video clip from 0.25× through 4× and remap linked layers to the edited clock.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                        "rate": .object([
                            "type": "number",
                            "minimum": 0.25,
                            "maximum": 4.0,
                        ]),
                    ],
                    required: ["clip_id", "rate"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_insert_freeze",
                title: "Insert a freeze frame",
                description: "Insert a positive-duration still frame after one clip at a source recording time.",
                inputSchema: Self.revisionedProjectSchema(
                    properties: [
                        "clip_id": .object(["type": "string"]),
                        "source_time": .object([
                            "type": "number",
                            "minimum": 0.0,
                        ]),
                        "duration": .object([
                            "type": "number",
                            "exclusiveMinimum": 0.0,
                        ]),
                    ],
                    required: ["clip_id", "source_time", "duration"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_undo_project",
                title: "Undo one project edit",
                description: "Undo one complete Storybird project edit.",
                inputSchema: Self.revisionedProjectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_redo_project",
                title: "Redo one project edit",
                description: "Redo one previously undone Storybird project edit.",
                inputSchema: Self.revisionedProjectSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_update_project",
                title: "Update project text",
                description: "Update a project's name and/or summary through Storybird.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "name": .object(["type": "string"]),
                        "summary": .object(["type": "string"]),
                    ],
                    required: ["project_id", "expected_revision"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_update_click",
                title: "Update a click layer",
                description: "Update one timed click caption, normalized position, or background style and return the new project revision.",
                inputSchema: Self.revisionedProjectSchema(properties: clickProperties, required: ["click_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_upsert_subtitle",
                title: "Add or update a subtitle",
                description: "Add or update one timed top or bottom subtitle layer and return the new project revision.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "subtitle_id": .object(["type": "string"]),
                        "timing_mode": .object(["type": "string", "enum": ["project", "scene"]]),
                        "start_time": .object(["type": "number", "minimum": 0.0]),
                        "end_time": .object(["type": "number", "minimum": 0.0]),
                        "text": .object(["type": "string"]),
                        "position": .object(["type": "string", "enum": ["top", "bottom"]]),
                        "background_hex": .object(["type": "string"]),
                        "background_opacity": .object(["type": "number", "minimum": 0.0, "maximum": 1.0]),
                        "foreground_hex": .object(["type": "string"]),
                        "font_size": .object(["type": "number", "minimum": 1.0]),
                    ],
                    required: [
                        "project_id",
                        "expected_revision",
                        "start_time",
                        "end_time",
                    ]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_preview_project",
                title: "Open a Storybird video project",
                description: "Select the project and open Storybird's timeline editor and video preview.",
                inputSchema: Self.projectIDSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_render_preview",
                title: "Render a composited preview frame",
                description: "Return a project-resolution PNG, its actual rendered project time, visible layer IDs and incomplete Cue IDs. Non-frame-aligned requests resolve to a frame; use the returned time for verification. Does not edit the project.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "time": .object(["type": "number", "minimum": 0]),
                    ],
                    required: ["project_id", "time"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
        ]
    }

    private static var exportTools: [Tool] {
        [
            Tool(
                name: "storybird_start_export",
                title: "Start an MP4 export job",
                description: "Validate a project and start one asynchronous local MP4 export.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "parent_directory": .object(["type": "string"]),
                    ],
                    required: ["project_id", "parent_directory"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_get_export",
                title: "Get MP4 export status",
                description: "Return validation, rendering, completion, failure, or cancellation state and 0-100 progress.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "job_id": .object(["type": "string"]),
                    ],
                    required: ["job_id"]
                ),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_cancel_export",
                title: "Cancel an MP4 export",
                description: "Cancel one active export job without replacing an existing output.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "job_id": .object(["type": "string"]),
                    ],
                    required: ["job_id"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_export_project",
                title: "Export a Storybird project",
                description: "Render the original recording and timeline layers into a local H.264 MP4.",
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "parent_directory": .object(["type": "string"]),
                    ],
                    required: ["project_id", "parent_directory"]
                ),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_delete_project",
                title: "Delete a Storybird project",
                description: "Request deletion. Storybird shows a native confirmation before deleting.",
                inputSchema: Self.projectIDSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "storybird_stop_session",
                title: "Stop and save the Storybird video",
                description: "Drain pointer actions, finalize the silent MP4, and save the new video project.",
                inputSchema: Self.objectSchema(),
                annotations: .init(
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ),
        ]
    }

    /// Routes one MCP call to the session while converting failures into tool errors.
    private func callTool(
        _ parameters: CallTool.Parameters
    ) async -> CallTool.Result {
        if toolProfile == .compact,
           let group = StorybirdMCPToolGroup.all.first(where: { $0.name == parameters.name }) {
            do {
                let resolved = try group.resolve(parameters.arguments ?? [:], legacy: Self.exposedTools)
                return await callApp(name: resolved.name, arguments: resolved.arguments)
            } catch {
                return Self.toolError(error.localizedDescription)
            }
        }
        if toolProfile == .compact, StorybirdMCPToolGroup.replacedNames.contains(parameters.name) {
            return Self.toolError("Unknown Storybird tool: \(parameters.name)")
        }
        guard let tool = Self.exposedTools[parameters.name] else {
            return Self.toolError("Unknown Storybird tool: \(parameters.name)")
        }
        let arguments = parameters.arguments ?? [:]
        if let schema = tool.inputSchema.objectValue,
           schema["additionalProperties"]?.boolValue == false,
           let properties = schema["properties"]?.objectValue,
           let unknown = Set(arguments.keys).subtracting(properties.keys).sorted().first {
            return Self.toolError("Unknown argument for \(parameters.name): \(unknown). No changes were made.")
        }
        return await callApp(name: parameters.name, arguments: arguments)
    }

    /// Forwards one validated request and preserves the app's text, PNG and error flag.
    private func callApp(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let argumentsData = try JSONEncoder().encode(arguments)
            let response = try await client.call(
                name: name,
                argumentsJSON: argumentsData
            )
            var content: [Tool.Content] = [
                .text(text: response.text, annotations: nil, _meta: nil),
            ]
            if let imageData = response.imageData {
                content.append(
                    .image(
                        data: imageData.base64EncodedString(),
                        mimeType: "image/png",
                        annotations: nil,
                        _meta: nil
                    )
                )
            }
            return .init(content: content, isError: response.isError)
        } catch {
            return Self.toolError(error.localizedDescription)
        }
    }

    /// Formats routing and transport failures consistently without any further IPC.
    private static func toolError(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    /// Builds a closed JSON Schema object for MCP arguments.
    static func objectSchema(
        properties: [String: Value] = [:],
        required: [String] = []
    ) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ])
    }

    /// Builds the shared normalized x/y schema for pointer tools.
    private static func pointerSchema(
        extraProperties: [String: Value],
        extraRequired: [String]
    ) -> Value {
        var properties: [String: Value] = [
            "x": .object([
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
                "description": "Normalized horizontal coordinate in the selected source.",
            ]),
            "y": .object([
                "type": "number",
                "minimum": 0.0,
                "maximum": 1.0,
                "description": "Normalized vertical coordinate in the selected source.",
            ]),
        ]
        properties.merge(extraProperties) { _, replacement in replacement }
        return objectSchema(
            properties: properties,
            required: ["x", "y"] + extraRequired
        )
    }

    /// Builds the shared project identifier schema.
    private static func projectIDSchema() -> Value {
        objectSchema(
            properties: [
                "project_id": .object([
                    "type": "string",
                    "description": "Storybird project UUID.",
                ]),
            ],
            required: ["project_id"]
        )
    }

    /// Builds the optimistic-concurrency envelope shared by project mutations.
    private static func revisionedProjectSchema(
        properties extraProperties: [String: Value] = [:],
        required extraRequired: [String] = []
    ) -> Value {
        var properties: [String: Value] = [
            "project_id": .object([
                "type": "string",
                "description": "Storybird project UUID.",
            ]),
            "expected_revision": .object([
                "type": "integer",
                "minimum": 0,
                "description": "Revision returned by the latest project read or edit.",
            ]),
        ]
        properties.merge(extraProperties) { _, replacement in replacement }
        return objectSchema(
            properties: properties,
            required: ["project_id", "expected_revision"] + extraRequired
        )
    }

    /// Marks real pointer tools as open-world and potentially destructive.
    private static var pointerAnnotations: Tool.Annotations {
        .init(
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: true
        )
    }

}
