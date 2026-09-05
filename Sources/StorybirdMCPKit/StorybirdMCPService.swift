import Foundation
import MCP

public struct StorybirdMCPService: Sendable {
    private let client: StorybirdAppIPCClient

    public init(client: StorybirdAppIPCClient = .init()) {
        self.client = client
    }

    /// Runs one local stdio MCP connection and aborts capture when it closes.
    public func run() async throws {
        let server = Server(
            name: "storybird",
            version: "0.1.0",
            title: "Storybird Computer Use",
            instructions: """
            Use one selected display or window per session. Starting a session \
            shares that source with the MCP client and allows real pointer \
            movement, clicks, and scrolling while Storybird records a local \
            silent video. These tools do not authorize \
            purchases, messages, uploads, account changes, or other external \
            side effects. Keyboard input and audio recording are not provided.
            """,
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await callTool(parameters)
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            await abortActiveSession()
            throw error
        }
        await abortActiveSession()
    }

    /// Ends any app-owned capture when the stdio client disappears without Stop.
    func abortActiveSession() async {
        _ = try? await client.call(
            name: "storybird_abort_session",
            argumentsJSON: Data("{}".utf8)
        )
    }

    /// Defines the public computer-use surface and its side-effect hints.
    static var toolDefinitions: [Tool] {
        sourceTools + projectTools + exportTools
    }

    private static var sourceTools: [Tool] {
        [
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
                pointer input after Storybird's native approval.
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
                name: "storybird_undo_project",
                title: "Undo one project edit",
                description: "Undo one complete Storybird project edit.",
                inputSchema: Self.projectIDSchema(),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "storybird_redo_project",
                title: "Redo one project edit",
                description: "Redo one previously undone Storybird project edit.",
                inputSchema: Self.projectIDSchema(),
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
                inputSchema: Self.objectSchema(
                    properties: [
                        "project_id": .object(["type": "string"]),
                        "expected_revision": .object(["type": "integer", "minimum": 0]),
                        "click_id": .object(["type": "string"]),
                        "caption": .object(["type": "string"]),
                        "x": .object(["type": "number", "minimum": 0.0, "maximum": 1.0]),
                        "y": .object(["type": "number", "minimum": 0.0, "maximum": 1.0]),
                        "background_hex": .object(["type": "string"]),
                        "background_opacity": .object(["type": "number", "minimum": 0.0, "maximum": 1.0]),
                    ],
                    required: ["project_id", "expected_revision", "click_id"]
                ),
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
                        "start_time": .object(["type": "number", "minimum": 0.0]),
                        "end_time": .object(["type": "number", "minimum": 0.0]),
                        "text": .object(["type": "string"]),
                        "position": .object(["type": "string", "enum": ["top", "bottom"]]),
                        "background_hex": .object(["type": "string"]),
                        "background_opacity": .object(["type": "number", "minimum": 0.0, "maximum": 1.0]),
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
                description: "Return one project-resolution PNG with the visible Storybird layers at project time.",
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
        do {
            let argumentsData = try JSONEncoder().encode(
                parameters.arguments ?? [:]
            )
            let response = try await client.call(
                name: parameters.name,
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
            return .init(
                content: [
                    .text(
                        text: error.localizedDescription,
                        annotations: nil,
                        _meta: nil
                    ),
                ],
                isError: true
            )
        }
    }

    /// Builds a closed JSON Schema object for MCP arguments.
    private static func objectSchema(
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
