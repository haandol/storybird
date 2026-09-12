import Foundation
import MCP
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

@MainActor
final class MCPCompactToolTests: XCTestCase {
    /// Invalid launch options must fail before any server or app access.
    func test_profileArguments_preserveDefaultAndRejectUnknownConfigurations() throws {
        XCTAssertEqual(try StorybirdMCPToolProfile(arguments: []), .legacy)
        XCTAssertEqual(try StorybirdMCPToolProfile(arguments: ["--tool-profile", "legacy"]), .legacy)
        XCTAssertEqual(try StorybirdMCPToolProfile(arguments: ["--tool-profile", "compact"]), .compact)
        for arguments in [["compact"], ["--tool-profile"], ["--tool-profile", "other"],
                          ["--tool-profile", "compact", "extra"], ["--unknown", "compact"]] {
            XCTAssertThrowsError(try StorybirdMCPToolProfile(arguments: arguments))
        }
    }

    /// Checks each independent route's fields, envelope, bounds and annotations.
    func test_compactSchemas_preserveEveryBranchPropertyAndRequiredField() throws {
        let legacy = Dictionary(uniqueKeysWithValues: StorybirdMCPService.toolDefinitions.map { ($0.name, $0) })
        let compact = Dictionary(uniqueKeysWithValues: StorybirdMCPService.toolDefinitions(for: .compact).map { ($0.name, $0) })
        XCTAssertEqual(legacy.count, 71)
        XCTAssertEqual(compact.count, 53)
        XCTAssertEqual(Set(legacy.keys).intersection(compact.keys).count, 44)
        let removed = Set(MCPProfileTestClient.routes.map { "storybird_" + $0.legacy })
        XCTAssertEqual(Set(legacy.keys).subtracting(compact.keys), removed)
        for route in MCPProfileTestClient.routes where route.legacy != "delete_narration" {
            let original = try XCTUnwrap(legacy["storybird_" + route.legacy])
            let grouped = try XCTUnwrap(compact["storybird_" + route.compact])
            let schema = try XCTUnwrap(grouped.inputSchema.objectValue)
            let branches = try XCTUnwrap(schema["oneOf"]?.arrayValue)
            let choice = try XCTUnwrap(branches.first {
                $0.objectValue?["properties"]?.objectValue?[route.selector]?.objectValue?["const"]?.stringValue == route.value
            })
            let input = try XCTUnwrap(choice.objectValue?["properties"]?.objectValue?["input"]?.objectValue)
            let originalSchema = try XCTUnwrap(original.inputSchema.objectValue)
            var expectedProperties = try XCTUnwrap(originalSchema["properties"]?.objectValue).filter {
                !["project_id", "expected_revision"].contains($0.key)
            }
            if ["create_spotlight", "update_effect"].contains(route.legacy) {
                for key in ["width", "height"] {
                    expectedProperties[key] = .object(["type": "number", "exclusiveMinimum": 0, "maximum": 1])
                }
            } else if route.legacy == "update_suggestion" {
                var spotlight = expectedProperties["spotlight"]!.objectValue!
                var fields = spotlight["properties"]!.objectValue!
                for key in ["width", "height"] {
                    fields[key] = .object(["type": "number", "exclusiveMinimum": 0, "maximum": 1])
                }
                spotlight["properties"] = .object(fields)
                expectedProperties["spotlight"] = .object(spotlight)
            }
            XCTAssertEqual(input["properties"], .object(expectedProperties), route.legacy)
            let expectedRequired = try XCTUnwrap(originalSchema["required"]?.arrayValue).filter {
                !["project_id", "expected_revision"].contains($0.stringValue ?? "")
            }
            XCTAssertEqual(input["required"], .array(expectedRequired), route.legacy)
            XCTAssertEqual(input["additionalProperties"], false)
            XCTAssertEqual(schema["additionalProperties"], false)
            XCTAssertEqual(Set(schema["required"]!.arrayValue!.compactMap(\.stringValue)),
                           ["project_id", "expected_revision", route.selector, "input"])
            XCTAssertEqual(grouped.annotations.readOnlyHint, false)
            XCTAssertEqual(grouped.annotations.destructiveHint, false)
            XCTAssertEqual(grouped.annotations.idempotentHint, false)
            XCTAssertEqual(grouped.annotations.openWorldHint, false)
        }
        // All ungrouped tools preserve the actual serialized definitions.
        for name in Set(legacy.keys).intersection(compact.keys) {
            XCTAssertEqual(legacy[name]?.inputSchema, compact[name]?.inputSchema)
            XCTAssertEqual(legacy[name]?.description, compact[name]?.description)
            XCTAssertEqual(legacy[name]?.annotations, compact[name]?.annotations)
        }
    }

    /// Exercises every branch through production handlers using a recording IPC probe.
    func test_compactCalls_routeEachOperationOnceAndPreserveAppResponses() async throws {
        let probe = CompactIPCProbe()
        try await withClient(profile: .compact, sender: { request in
            await probe.append(request)
            return StorybirdControlResponse(text: "app-response", imageData: Data([1, 2, 3]), isError: true)
        }) { raw, initialization in
            XCTAssertTrue(initialization.instructions?.contains("Tool profile: compact") == true)
            let client = MCPProfileTestClient(client: raw, profile: .compact)
            let tools = try await raw.listTools().tools
            XCTAssertEqual(tools.count, 53)
            let repeated = try await raw.listTools().tools
            XCTAssertEqual(tools.map(\.name), repeated.map(\.name))
            let legacy = Dictionary(uniqueKeysWithValues: StorybirdMCPService.toolDefinitions.map { ($0.name, $0) })
            for route in MCPProfileTestClient.routes {
                let tool = try XCTUnwrap(legacy["storybird_" + route.legacy])
                let fields = try XCTUnwrap(tool.inputSchema.objectValue?["properties"]?.objectValue)
                let required = try XCTUnwrap(tool.inputSchema.objectValue?["required"]?.arrayValue)
                var arguments: [String: Value] = [:]
                for key in required.compactMap(\.stringValue) {
                    arguments[key] = sample(try XCTUnwrap(fields[key]))
                }
                let response = try await client.callTool(name: tool.name, arguments: arguments)
                XCTAssertEqual(response.isError, true, "App errors must not become successes.")
                XCTAssertEqual(response.content.count, 2)
                guard case let .text(text, _, _) = response.content[0],
                      case let .image(data, mime, _, _) = response.content[1] else {
                    return XCTFail("Original text and image response must survive routing.")
                }
                XCTAssertEqual(text, "app-response")
                XCTAssertEqual(data, Data([1, 2, 3]).base64EncodedString())
                XCTAssertEqual(mime, "image/png")
                let requests = await probe.requests
                let request = try XCTUnwrap(requests.last)
                let expectedName = route.legacy == "delete_narration" ? "delete_audio_layer" : route.legacy
                XCTAssertEqual(request.name, "storybird_" + expectedName)
                var expected = arguments
                if route.legacy == "delete_narration" {
                    expected["layer_id"] = expected.removeValue(forKey: "narration_id")
                }
                XCTAssertEqual(try JSONDecoder().decode([String: Value].self, from: request.argumentsJSON), expected)
            }
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 27, "Exactly one app call per public request.")
        }
    }

    /// Rejects malformed, cross-branch and hidden-alias calls before any app request.
    func test_invalidCompactBranches_neverReachApp() async throws {
        let probe = CompactIPCProbe()
        try await withClient(profile: .compact, sender: { request in
            await probe.append(request)
            return StorybirdControlResponse(text: "Must not execute")
        }) { client, _ in
            let valid: [String: Value] = [
                "project_id": "project", "expected_revision": 0, "action": "update",
                "input": .object(["click_id": "click", "description": "Must not save"]),
            ]
            var cases: [[String: Value]] = []
            for key in ["project_id", "expected_revision", "action", "input"] {
                var missing = valid
                missing.removeValue(forKey: key)
                cases.append(missing)
            }
            for replacement: [String: Value] in [
                ["action": "other"], ["action": true], ["unexpected": 1],
                ["input": "not an object"], ["input": .null],
                ["expected_revision": true], ["expected_revision": 0.5], ["expected_revision": -1],
                ["project_id": false],
                ["input": .object(["description": "missing ID"])],
                ["input": .object(["click_id": "click", "source_start": 1])],
                ["input": .object(["click_id": "click", "time": true])],
                ["input": .object(["click_id": "click", "x": 1.01])],
                ["input": .object(["click_id": "click", "indicator_size": 0])],
                ["input": .object(["click_id": "click", "subtitle_position": "middle"])],
                ["input": .object(["click_id": "click", "expected_revision": 4])],
            ] {
                cases.append(valid.merging(replacement) { _, new in new })
            }
            for arguments in cases {
                let response = try await client.callTool(name: "storybird_edit_click", arguments: arguments)
                XCTAssertEqual(response.isError, true, "\(arguments)")
            }
            for (name, arguments): (String, [String: Value]) in [
                ("storybird_edit_suggestion", [
                    "project_id": "project", "expected_revision": 0, "action": "update",
                    "input": .object(["suggestion_id": "suggestion", "spotlight": .object(["dim_opactiy": 0.5])]),
                ]),
                ("storybird_edit_clip", [
                    "project_id": "project", "expected_revision": 0, "action": "set_speed",
                    "input": .object(["clip_id": "clip", "rate": 4.01]),
                ]),
                ("storybird_insert_card", [
                    "project_id": "project", "expected_revision": 0, "kind": "cta",
                    "input": .object(["title": "End", "duration": 1]),
                ]),
            ] {
                let response = try await client.callTool(name: name, arguments: arguments)
                XCTAssertEqual(response.isError, true, name)
            }
            for name in MCPProfileTestClient.routes.map({ "storybird_" + $0.legacy }) + ["storybird_unadvertised"] {
                let response = try await client.callTool(name: name, arguments: [:])
                XCTAssertEqual(response.isError, true, name)
            }
            let requests = await probe.requests
            XCTAssertTrue(requests.isEmpty)
        }
        try await withClient(profile: .legacy, sender: { _ in
            XCTFail("Compact names must not run on legacy connections")
            return StorybirdControlResponse(text: "unexpected")
        }) { client, initialization in
            XCTAssertTrue(initialization.instructions?.contains("Tool profile: legacy") == true)
            for name in Set(MCPProfileTestClient.routes.map({ "storybird_" + $0.compact })) {
                let response = try await client.callTool(name: name, arguments: [:])
                XCTAssertEqual(response.isError, true)
            }
        }
    }

    /// Static rectangle bounds are enforced before IPC for each spotlight entry path.
    func test_zeroSpotlightDimensions_rejectBeforeAppAndKeepLegacySchemas() async throws {
        let probe = CompactIPCProbe()
        try await withClient(profile: .compact, sender: { request in
            await probe.append(request)
            return StorybirdControlResponse(text: "Must not execute")
        }) { client, _ in
            for dimension in ["width", "height"] {
                let rectangle: [String: Value] = [
                    "start_time": 0, "end_time": 1, "x": 0.2, "y": 0.2,
                    "width": 0.5, "height": 0.5,
                ].merging([dimension: 0]) { _, new in new }
                for (name, selector, selection, input): (String, String, String, [String: Value]) in [
                    ("storybird_create_visual_effect", "kind", "spotlight", rectangle),
                    ("storybird_edit_effect", "action", "update", ["effect_id": "effect", dimension: 0]),
                    ("storybird_edit_suggestion", "action", "update",
                     ["suggestion_id": "suggestion", "spotlight": .object([dimension: 0])]),
                ] {
                    let result = try await client.callTool(name: name, arguments: [
                        "project_id": "project", "expected_revision": 0, selector: .string(selection),
                        "input": .object(input),
                    ])
                    XCTAssertEqual(result.isError, true, "\(name).\(dimension)")
                }
            }
            let requests = await probe.requests
            XCTAssertTrue(requests.isEmpty)
        }
        let legacy = try XCTUnwrap(StorybirdMCPService.toolDefinitions.first { $0.name == "storybird_create_spotlight" })
        for key in ["width", "height"] {
            let field = legacy.inputSchema.objectValue?["properties"]?.objectValue?[key]?.objectValue
            XCTAssertEqual(field?["minimum"], 0)
            XCTAssertNil(field?["exclusiveMinimum"])
        }
    }

    /// A failed library write must retain the current value and the undo entry.
    func test_compactSaveFailure_preservesProjectRevisionAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Unchanged")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = try XCTUnwrap(store.project(id: project.id))
        edited.name = "One committed edit"
        let before = try store.saveProject(edited, expectedRevision: 0)
        let host = StorybirdExternalControlHost(store: store)
        try await withClient(profile: .compact, sender: { await host.handle($0) }) { client, _ in
            let library = root.appendingPathComponent("library.json")
            let backup = root.appendingPathComponent("backup.json")
            try FileManager.default.moveItem(at: library, to: backup)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            let response = try await client.callTool(name: "storybird_edit_history", arguments: [
                "project_id": .string(project.id.uuidString), "expected_revision": .int(before.revision),
                "action": "undo", "input": .object([:]),
            ])
            XCTAssertEqual(response.isError, true)
            XCTAssertEqual(store.project(id: project.id), before)
            try FileManager.default.removeItem(at: library)
            try FileManager.default.moveItem(at: backup, to: library)
            let retried = try await client.callTool(name: "storybird_edit_history", arguments: [
                "project_id": .string(project.id.uuidString), "expected_revision": .int(before.revision),
                "action": "undo", "input": .object([:]),
            ])
            XCTAssertNotEqual(retried.isError, true)
            XCTAssertEqual(store.project(id: project.id)?.name, "Unchanged")
            XCTAssertEqual(store.project(id: project.id)?.revision, before.revision + 1)
        }
    }

    /// Supplies type-correct minimal wire fixtures for dispatch-only tests.
    private func sample(_ schema: Value) -> Value {
        let fields = schema.objectValue!
        if let first = fields["enum"]?.arrayValue?.first { return first }
        switch fields["type"]?.stringValue {
        case "string": return "fixture-id"
        case "integer": return 0
        case "number": return 1
        case "boolean": return false
        default: return .object([:])
        }
    }

    /// Connects production handlers over in-memory transport with no real app launch.
    private func withClient(
        profile: StorybirdMCPToolProfile,
        sender: @escaping @Sendable (StorybirdControlRequest) async throws -> StorybirdControlResponse,
        _ body: (Client, Initialize.Result) async throws -> Void
    ) async throws {
        let ipc = StorybirdAppIPCClient(sender: sender, launcher: {
            XCTFail("These tests must not launch the user's app")
            throw StorybirdMCPToolInputError(message: "Unexpected app launch")
        })
        let transport = await InMemoryTransport.createConnectedPair()
        let server = try await StorybirdMCPService(client: ipc, toolProfile: profile).startServer(transport: transport.server)
        let client = Client(name: "Compact protocol test", version: "1")
        do {
            let initialization = try await client.connect(transport: transport.client)
            try await body(client, initialization)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }
}

private actor CompactIPCProbe {
    private(set) var requests: [StorybirdControlRequest] = []
    /// Records app-bound requests without touching a socket or project library.
    func append(_ request: StorybirdControlRequest) { requests.append(request) }
}
