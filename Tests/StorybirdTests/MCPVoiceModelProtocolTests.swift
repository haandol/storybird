import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPVoiceModelProtocolTests: XCTestCase {
    func test_modelWorkflow_discoversSelectsPreparesAndGeneratesWithoutNativeApproval() async throws {
        try await withClient { client, store, project, large, small in
            let tools = try await client.listTools().tools
            let prepare = try XCTUnwrap(tools.first { $0.name == "storybird_prepare_voice_model" })
            XCTAssertEqual(prepare.annotations.openWorldHint, true)
            XCTAssertEqual(prepare.annotations.destructiveHint, false)
            let list = try await client.callTool(name: "storybird_list_voice_models")
            let models: [VoiceModelSnapshot] = try decode(list)
            XCTAssertEqual(models.count, 2)
            XCTAssertTrue(models.allSatisfy { $0.quantizationBits == 8 })
            XCTAssertEqual(models.first(where: \.selected)?.id, VoiceModel.base1_7B.rawValue)
            let arguments: [String: Value] = ["model_id": .string(VoiceModel.base0_6B.rawValue)]
            let selected = try await client.callTool(name: "storybird_select_voice_model", arguments: arguments)
            XCTAssertNotEqual(selected.isError, true)
            XCTAssertEqual(store.selectedVoiceModel, .base0_6B)
            let before = store.projects
            let pending = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            let pendingModel: VoiceModelSnapshot = try decode(pending)
            XCTAssertEqual(pendingModel.state, "preparing")
            let duplicate = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            let same: VoiceModelSnapshot = try decode(duplicate)
            XCTAssertEqual(same.state, "preparing")
            let blocked = try await client.callTool(name: "storybird_select_voice_model",
                                                   arguments: ["model_id": .string(VoiceModel.base1_7B.rawValue)])
            XCTAssertEqual(blocked.isError, true)
            await small.finishPreparation()
            let ready = try await poll(client, model: .base0_6B)
            XCTAssertEqual(ready.state, "ready")
            XCTAssertEqual(store.projects, before)
            XCTAssertNil(store.externalControlPrompt)
            XCTAssertNil(store.permissionPrompt)
            let preparedCalls = await small.prepareCalls
            XCTAssertEqual(preparedCalls, 1)

            let generated = try await client.callTool(name: "storybird_start_narration_draft", arguments: [
                "project_id": .string(project.id.uuidString),
                "voice_profile_id": .string(store.voiceProfiles[0].id.uuidString),
                "text": .string("Synthetic speech from the selected small model."),
                "language": .string("english"),
            ])
            var draft: NarrationDraft = try decode(generated)
            for _ in 0..<200 {
                if draft.state != .generating { break }
                try await Task.sleep(for: .milliseconds(10))
                draft = try decode(try await client.callTool(name: "storybird_get_narration_draft", arguments: [
                    "project_id": .string(project.id.uuidString), "draft_id": .string(draft.id.uuidString),
                ]))
            }
            XCTAssertEqual(draft.state, .ready)
            let smallGenerations = await small.generationCalls
            let largeGenerations = await large.generationCalls
            XCTAssertEqual(smallGenerations, 1)
            XCTAssertEqual(largeGenerations, 0)
            XCTAssertEqual(store.project(id: project.id)?.revision, 0)
        }
    }

    func test_invalidModelArguments_rejectWithoutDownloadingOrChangingSelection() async throws {
        try await withClient { client, store, _, large, small in
            for name in ["storybird_get_voice_model", "storybird_select_voice_model", "storybird_prepare_voice_model"] {
                for arguments: [String: Value] in [
                    ["model_id": .string("unapproved-model")],
                    ["model_id": true],
                    ["model_id": .string(VoiceModel.base0_6B.rawValue), "approve": true],
                ] {
                    let result = try await client.callTool(name: name, arguments: arguments)
                    XCTAssertEqual(result.isError, true)
                }
            }
            XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
            let largeCalls = await large.prepareCalls
            let smallCalls = await small.prepareCalls
            XCTAssertEqual(largeCalls + smallCalls, 0)
        }
    }

    func test_preparationFailure_isPollableAndRetryDoesNotChangeSelectedModel() async throws {
        try await withClient { client, store, project, _, small in
            let arguments: [String: Value] = ["model_id": .string(VoiceModel.base0_6B.rawValue)]
            let before = store.projects
            _ = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            await small.finishPreparation(fail: true)
            let failed = try await poll(client, model: .base0_6B)
            XCTAssertEqual(failed.state, "failed")
            XCTAssertNotNil(failed.error)
            XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
            XCTAssertEqual(store.projects, before)
            await small.allowSuccess()
            _ = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            let ready = try await poll(client, model: .base0_6B)
            XCTAssertEqual(ready.state, "ready")
            XCTAssertFalse(ready.selected)
            XCTAssertEqual(store.project(id: project.id)?.revision, 0)
            XCTAssertNil(store.externalControlPrompt)
            let calls = await small.prepareCalls
            XCTAssertEqual(calls, 2)
        }
    }

    private func poll(_ client: Client, model: VoiceModel) async throws -> VoiceModelSnapshot {
        for _ in 0..<200 {
            let result = try await client.callTool(name: "storybird_get_voice_model",
                                                 arguments: ["model_id": .string(model.rawValue)])
            let snapshot: VoiceModelSnapshot = try decode(result)
            if snapshot.state != "preparing" { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ModelProtocolTimeout", code: 1)
    }

    private func decode<T: Decodable>(_ result: (content: [Tool.Content], isError: Bool?)) throws -> T {
        XCTAssertNotEqual(result.isError, true)
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            throw NSError(domain: "ModelProtocolResponse", code: 1)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    private func withClient(
        _ body: (Client, AppStore, DemoProject, ModelTestProvider, ModelTestProvider) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-protocol-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let media = try repository.prepareVideoRecordingURL(projectID: id)
        let movie = try await TestVideoFactory.makeMovie(at: media.url, includeAudio: false, duration: 3)
        let project = DemoProject(id: id, name: "Synthetic model protocol", recording: VideoRecordingAsset(
            filename: media.filename, duration: movie.duration, width: movie.width, height: movie.height))
        try repository.saveProjects([project])
        try repository.saveVoiceProfiles([VoiceProfile(name: "Synthetic", referenceFilename: "reference.wav",
                                                       referenceText: "Synthetic reference", consentConfirmed: true)])
        let large = ModelTestProvider(ready: true)
        let small = ModelTestProvider(hold: true)
        let store = AppStore(repository: repository,
                             voiceModelServices: [.base1_7B: large, .base0_6B: small])
        let host = StorybirdExternalControlHost(store: store)
        let ipc = StorybirdAppIPCClient(sender: { await host.handle($0) },
                                       launcher: { throw NSError(domain: "UnexpectedAppLaunch", code: 1) })
        let server = await StorybirdMCPService(client: ipc).makeServer()
        let transport = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transport.server)
        let client = Client(name: "Model workflow test", version: "1")
        do {
            _ = try await client.connect(transport: transport.client)
            try await body(client, store, project, large, small)
            await small.finishPreparation()
            await client.disconnect()
            await server.stop()
        } catch {
            await small.finishPreparation()
            await client.disconnect()
            await server.stop()
            throw error
        }
    }
}
