import AVFoundation
import Foundation
import MCP
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

@MainActor
final class MCPAudioProtocolTests: XCTestCase {
    func test_mcpDiscovery_exposesProductionWorkflowAndMatchingAudioConstraints() async throws {
        try await withClient { client, _, _, probe, initialization in
            XCTAssertEqual(initialization.serverInfo.title, "Storybird Video Production")
            XCTAssertTrue(initialization.instructions?.contains("storybird_start_narration_draft") == true)
            let tools = try await client.listTools().tools
            let names = tools.map(\.name)
            XCTAssertEqual(Set(names).count, names.count)
            let edits = ["storybird_place_audio_asset", "storybird_update_audio_layer",
                "storybird_split_audio_layer", "storybird_duplicate_audio_layer",
                "storybird_delete_audio_layer", "storybird_set_source_audio"]
            for name in edits {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let schema = try schema(tool)
                XCTAssertTrue((schema["required"] as? [String])?.contains("expected_revision") == true)
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
                XCTAssertEqual(tool.annotations.destructiveHint, false)
            }
            for name in ["storybird_place_audio_asset", "storybird_update_audio_layer", "storybird_render_audio_preview"] {
                let properties = try properties(XCTUnwrap(tools.first { $0.name == name }))
                let duration = try XCTUnwrap(properties["duration"] as? [String: Any])
                XCTAssertEqual(duration["exclusiveMinimum"] as? Double, 0)
            }
            let legacy = try XCTUnwrap(tools.first { $0.name == "storybird_update_narration" })
            let gain = try XCTUnwrap(properties(legacy)["volume"] as? [String: Any])
            XCTAssertNil(gain["maximum"], "Legacy narration must accept the same gain as the audio editor.")
            XCTAssertEqual(legacy.annotations.idempotentHint, false, "Regeneration creates a new asset.")
            let unknown = try await client.callTool(name: "storybird_not_a_tool", arguments: [:])
            XCTAssertEqual(unknown.isError, true)
            let calls = await probe.calls
            XCTAssertFalse(calls.contains("storybird_not_a_tool"), "Unadvertised names must not reach app IPC.")
        }
    }

    /// Keeps the legacy audio production path covered through the MCP client.
    func test_mcpTTSProduction_editsOverlappingAudioAndExportsThroughProtocol() async throws {
        try await assertAudioProduction(profile: .legacy)
    }

    /// Applies the same audio and export expectations to the compact editing tools.
    func test_compactTTSProduction_preservesOverlappingAudioAndCompletedExport() async throws {
        try await assertAudioProduction(profile: .compact)
    }

    /// Verifies draft generation, placement, layered audio and export in one profile.
    private func assertAudioProduction(profile: StorybirdMCPToolProfile) async throws {
        try await withClient(profile: profile) { client, store, initial, _, _ in
            let projectID = Value.string(initial.id.uuidString)
            let generated = try await client.callTool(name: "storybird_start_narration_draft", arguments: [
                "project_id": projectID, "voice_profile_id": .string(store.voiceProfiles[0].id.uuidString),
                "text": "Create the video from this script.", "language": "english",
            ])
            XCTAssertNotEqual(generated.isError, true)
            let draft: NarrationDraft = try decode(generated.content)
            var ready = draft
            for _ in 0..<500 {
                let response = try await client.callTool(name: "storybird_get_narration_draft", arguments: [
                    "project_id": projectID, "draft_id": .string(draft.id.uuidString),
                ])
                ready = try decode(response.content)
                if ready.state != .generating { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(ready.state, .ready)
            XCTAssertEqual(ready.duration, 1)
            XCTAssertEqual(store.project(id: initial.id)?.revision, 0)
            let placed = try await client.callTool(name: "storybird_place_narration_draft", arguments: [
                "project_id": projectID, "draft_id": .string(draft.id.uuidString),
                "expected_revision": 0, "start_time": 1,
            ])
            XCTAssertNotEqual(placed.isError, true)
            var current: DemoProject = try decode(placed.content)
            let layerID = Value.string(current.narrations[0].id.uuidString)
            let beforeInvalidRevision = try XCTUnwrap(store.project(id: initial.id))
            for invalidRevision: Value in [true, 1.5] {
                let rejected = try await client.callTool(name: "storybird_update_narration", arguments: [
                    "project_id": projectID, "narration_id": layerID,
                    "expected_revision": invalidRevision, "volume": 0.8,
                ])
                XCTAssertEqual(rejected.isError, true)
                XCTAssertEqual(store.project(id: initial.id), beforeInvalidRevision)
            }
            let gain = try await client.callTool(name: "storybird_update_narration", arguments: [
                "project_id": projectID, "narration_id": layerID,
                "expected_revision": .int(current.revision), "volume": 3,
            ])
            XCTAssertNotEqual(gain.isError, true)
            current = try decode(gain.content)
            XCTAssertEqual(current.narrations[0].volume, 3)
            let beforeInvalidField = try XCTUnwrap(store.project(id: initial.id))

            for (field, value): (String, Value) in [("volume", true), ("start_time", true), ("text", false), ("language", false)] {
                let rejected = try await client.callTool(name: "storybird_update_narration", arguments: [
                    "project_id": projectID, "narration_id": layerID,
                    "expected_revision": .int(current.revision), field: value,
                ])
                XCTAssertEqual(rejected.isError, true)
                XCTAssertEqual(store.project(id: initial.id), beforeInvalidField)
            }
            let edited = try await client.callTool(name: "storybird_update_audio_layer", arguments: [
                "project_id": projectID, "layer_id": layerID, "expected_revision": .int(current.revision),
                "volume": 0.5, "fade_in": 0.1, "fade_out": 0.2,
            ])
            XCTAssertNotEqual(edited.isError, true)
            current = try decode(edited.content)
            let duplicate = try await client.callTool(name: "storybird_duplicate_audio_layer", arguments: [
                "project_id": projectID, "layer_id": layerID, "expected_revision": .int(current.revision),
                "start_time": 1.3,
            ])
            XCTAssertNotEqual(duplicate.isError, true)
            current = try decode(duplicate.content)
            XCTAssertEqual(current.narrations.count, 2)
            XCTAssertEqual(current.narrations[0].filename, current.narrations[1].filename)
            let preview = try await client.callTool(name: "storybird_render_audio_preview", arguments: [
                "project_id": projectID, "start_time": 0, "duration": 5,
            ])
            XCTAssertNotEqual(preview.isError, true)
            XCTAssertEqual(preview.content.count, 1, "Only local file metadata is returned.")
            let audio: AudioPreviewResult = try decode(preview.content)
            defer { try? FileManager.default.removeItem(atPath: audio.path) }
            XCTAssertEqual(audio.duration, 5, accuracy: 0.001)
            XCTAssertGreaterThan(audio.peak, 0)
            let export = try await client.callTool(name: "storybird_start_export", arguments: [
                "project_id": projectID, "parent_directory": .string(store.repository.rootURL.path),
            ])
            XCTAssertNotEqual(export.isError, true)
            var job: ProtocolExportJob = try decode(export.content)
            for _ in 0..<1_000 {
                if ["completed", "failed", "cancelled"].contains(job.state) { break }
                try await Task.sleep(for: .milliseconds(10))
                let result = try await client.callTool(name: "storybird_get_export", arguments: ["job_id": .string(job.id.uuidString)])
                job = try decode(result.content)
            }
            XCTAssertEqual(job.state, "completed")
            let output = try XCTUnwrap(job.outputPath)
            let tracks = try await AVURLAsset(url: URL(fileURLWithPath: output)).loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            XCTAssertNil(store.externalControlPrompt)
        }
    }

    /// Runs the production MCP handlers, wire encoding and app host together;
    /// injected IPC and TTS keep the real socket, profiles and microphone untouched.
    private func withClient(
        profile: StorybirdMCPToolProfile = .legacy,
        _ body: (MCPProfileTestClient, AppStore, DemoProject, ProtocolIPCProbe, Initialize.Result) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository(rootURL: root)
        let id = UUID()
        let video = try repo.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: video.url, includeAudio: false, duration: 5)
        let project = DemoProject(id: id, name: "MCP production", recording: VideoRecordingAsset(
            filename: video.filename, duration: media.duration, width: media.width, height: media.height
        ))
        try repo.saveProjects([project])
        try repo.saveVoiceProfiles([VoiceProfile(name: "Synthetic", referenceFilename: "reference.wav",
            referenceText: "Synthetic reference", consentConfirmed: true)])
        let store = AppStore(repository: repo, voiceService: ProtocolVoice())
        let host = StorybirdExternalControlHost(store: store)
        let probe = ProtocolIPCProbe()
        let ipc = StorybirdAppIPCClient(sender: { request in
            await probe.record(request.name)
            return await host.handle(request)
        }, launcher: { throw ProtocolFixtureError.unexpectedLaunch })
        let server = await StorybirdMCPService(client: ipc, toolProfile: profile).makeServer()
        let transport = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transport.server)
        let client = Client(name: "Audio production test", version: "1")
        do {
            let initialization = try await client.connect(transport: transport.client)
            try await body(MCPProfileTestClient(client: client, profile: profile), store, project, probe, initialization)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Reads actual protocol JSON content rather than app-returned values directly.
    private func decode<T: Decodable>(_ content: [Tool.Content]) throws -> T {
        guard case let .text(text, _, _) = try XCTUnwrap(content.first) else { throw ProtocolFixtureError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    private func schema(_ tool: Tool) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any])
    }

    private func properties(_ tool: Tool) throws -> [String: Any] {
        try XCTUnwrap(schema(tool)["properties"] as? [String: Any])
    }
}

private enum ProtocolFixtureError: Error { case unexpectedLaunch, invalidResponse }
private struct ProtocolExportJob: Decodable { let id: UUID; let state: String; let outputPath: String? }
private actor ProtocolIPCProbe {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}
private actor ProtocolVoice: VoiceSynthesisProviding {
    func prepared() -> Bool { true }
    func prepare() async throws {}
    func generate(text: String, referenceAudioURL: URL, referenceText: String, language: String, outputURL: URL) async throws -> VoiceSynthesisResult {
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 1)
        return VoiceSynthesisResult(duration: 1, sampleRate: 44_100)
    }
}
