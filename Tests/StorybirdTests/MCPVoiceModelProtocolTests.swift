import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPVoiceModelProtocolTests: XCTestCase {
    func test_customVoice_failedCommitPreservesAudioInstructionsAndHistoryThenRetries() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: profile, includeVoiceProfile: false) { client, store, project, _, custom in
                await custom.finishPreparation()
                await store.prepareVoiceRuntime(model: .customVoice1_7B)
                let generated = try await store.generateNarration(
                    projectID: project.id, expectedRevision: 0, text: "Keep this sentence.",
                    language: "english", startTime: 0,
                    customVoice: CustomVoiceOptions(speaker: .sohee, instruct: "Calm"))
                let original = try XCTUnwrap(generated.narrations.first)
                let audioURL = store.repository.assetURL(projectID: project.id, filename: original.filename)
                let audioBytes = try Data(contentsOf: audioURL)
                let audioDirectory = audioURL.deletingLastPathComponent()
                let filesBefore = try Set(FileManager.default.contentsOfDirectory(atPath: audioDirectory.path))
                let library = store.repository.rootURL.appendingPathComponent("library.json")
                let backup = store.repository.rootURL.appendingPathComponent("library-before-failed-commit.json")
                let libraryBytes = try Data(contentsOf: library)
                let before = store.projects
                try FileManager.default.moveItem(at: library, to: backup)
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
                let rejected = try await client.callTool(name: "storybird_update_narration", arguments: [
                    "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                    "expected_revision": 1, "instruct": "Excited",
                ])
                XCTAssertEqual(rejected.isError, true)
                XCTAssertEqual(store.projects, before)
                XCTAssertEqual(try Data(contentsOf: audioURL), audioBytes)
                XCTAssertEqual(try Data(contentsOf: backup), libraryBytes)
                XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)), filesBefore)
                let synthesisCount = await custom.generationCalls
                let submittedText = await custom.lastText
                let submittedLanguage = await custom.lastLanguage
                let submittedVoice = await custom.lastCustomVoice
                XCTAssertEqual(synthesisCount, 2, "Synthesis must succeed before the injected commit failure.")
                XCTAssertEqual(submittedText, original.text)
                XCTAssertEqual(submittedLanguage, original.language)
                XCTAssertEqual(submittedVoice, CustomVoiceOptions(speaker: .sohee, instruct: "Excited"))
                try FileManager.default.removeItem(at: library)
                try FileManager.default.moveItem(at: backup, to: library)
                let undone = try store.undo(projectID: project.id, expectedRevision: 1)
                XCTAssertTrue(undone.narrations.isEmpty, "Failed save must not add an undo entry.")
                let redone = try store.redo(projectID: project.id, expectedRevision: undone.revision)
                XCTAssertEqual(redone.narrations.first, original)
                let retried: DemoProject = try decode(try await client.callTool(
                    name: "storybird_update_narration", arguments: [
                        "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                        "expected_revision": .int(redone.revision), "instruct": "Excited",
                    ]))
                XCTAssertEqual(retried.narrations.first?.customVoice, CustomVoiceOptions(speaker: .sohee, instruct: "Excited"))
                let restored = try store.undo(projectID: project.id, expectedRevision: retried.revision)
                XCTAssertEqual(restored.narrations.first, original)
                XCTAssertEqual(try Data(contentsOf: audioURL), audioBytes)
            }
        }
    }

    func test_customVoice_revisionChangedDuringSynthesisKeepsPreviousAudioAndInstruction() async throws {
        try await withClient(includeVoiceProfile: false) { client, store, project, _, custom in
            await custom.finishPreparation()
            await store.prepareVoiceRuntime(model: .customVoice1_7B)
            let generated = try await store.generateNarration(
                projectID: project.id, expectedRevision: 0, text: "Original",
                language: "english", startTime: 0,
                customVoice: CustomVoiceOptions(speaker: .sohee, instruct: "Calm"))
            let original = try XCTUnwrap(generated.narrations.first)
            await custom.suspendGeneration()
            let request = Task {
                try await client.callTool(name: "storybird_update_narration", arguments: [
                    "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                    "expected_revision": 1, "instruct": "Excited",
                ])
            }
            for _ in 0..<200 {
                if await custom.generationIsWaiting { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let waiting = await custom.generationIsWaiting
            XCTAssertTrue(waiting)
            var renamed = try XCTUnwrap(store.project(id: project.id))
            renamed.name = "Concurrent edit"
            _ = try store.saveProject(renamed, expectedRevision: 1)
            await custom.finishGeneration()
            let result = try await request.value
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(store.project(id: project.id)?.narrations.first, original)
            XCTAssertEqual(store.project(id: project.id)?.name, "Concurrent edit")
        }
    }

    func test_customVoice_instructionOnlyRegenerationPersistsAndUndoesInBothProfiles() async throws {
        for toolProfile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: toolProfile, includeVoiceProfile: false) { client, store, project, _, custom in
                await custom.finishPreparation()
                await store.prepareVoiceRuntime(model: .customVoice1_7B)
                let generated: NarrationDraft = try decode(try await client.callTool(
                    name: "storybird_start_narration_draft", arguments: [
                        "project_id": .string(project.id.uuidString), "text": "A synthetic sentence.",
                        "language": "english", "speaker": "sohee", "instruct": "Calm and warm.",
                    ]))
                let draft = try await pollDraft(client, projectID: project.id, draftID: generated.id)
                XCTAssertEqual(draft.state, .ready)
                XCTAssertNil(draft.voiceProfileID)
                XCTAssertEqual(draft.customVoice, CustomVoiceOptions(speaker: .sohee, instruct: "Calm and warm."))
                let placed: DemoProject = try decode(try await client.callTool(
                    name: "storybird_place_narration_draft", arguments: [
                        "project_id": .string(project.id.uuidString), "draft_id": .string(draft.id.uuidString),
                        "expected_revision": 0, "start_time": 0,
                    ]))
                let original = try XCTUnwrap(placed.narrations.first)
                let originalAudio = try Data(contentsOf: store.repository.assetURL(projectID: project.id, filename: original.filename))
                let regenerated: DemoProject = try decode(try await client.callTool(
                    name: "storybird_update_narration", arguments: [
                        "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                        "expected_revision": 1, "instruct": "Excited, with short pauses.",
                    ]))
                let changed = try XCTUnwrap(regenerated.narrations.first)
                XCTAssertEqual(regenerated.revision, 2)
                XCTAssertEqual(changed.text, original.text)
                XCTAssertEqual(changed.language, original.language)
                XCTAssertEqual(changed.customVoice, CustomVoiceOptions(speaker: .sohee, instruct: "Excited, with short pauses."))
                XCTAssertNotEqual(changed.filename, original.filename)
                let actualInstruction = await custom.lastCustomVoice
                XCTAssertEqual(actualInstruction, changed.customVoice)
                XCTAssertEqual(try Data(contentsOf: store.repository.assetURL(projectID: project.id, filename: original.filename)), originalAudio)
                let reopened = AppStore(repository: store.repository)
                XCTAssertEqual(reopened.project(id: project.id)?.narrations.first?.customVoice, changed.customVoice)
                let beforeFailure = store.projects
                for revision in [1, 2] {
                    if revision == 2 { await custom.finishGeneration(fail: true) }
                    let rejected = try await client.callTool(name: "storybird_update_narration", arguments: [
                        "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                        "expected_revision": .int(revision), "instruct": "Must not be committed.",
                    ])
                    XCTAssertEqual(rejected.isError, true)
                    XCTAssertEqual(store.projects, beforeFailure)
                }
                await custom.finishGeneration()
                let cleared: DemoProject = try decode(try await client.callTool(
                    name: "storybird_update_narration", arguments: [
                        "project_id": .string(project.id.uuidString), "narration_id": .string(original.id.uuidString),
                        "expected_revision": 2, "speaker": "ryan", "instruct": "",
                    ]))
                XCTAssertEqual(cleared.narrations.first?.customVoice, CustomVoiceOptions(speaker: .ryan))
                var history: [String: Value] = [
                    "project_id": .string(project.id.uuidString), "expected_revision": 3,
                ]
                if toolProfile == .compact { history["action"] = "undo"; history["input"] = .object([:]) }
                let undone: DemoProject = try decode(try await client.callTool(
                    name: toolProfile == .compact ? "storybird_edit_history" : "storybird_undo_project",
                    arguments: history))
                XCTAssertEqual(undone.narrations.first?.customVoice, changed.customVoice)
                XCTAssertEqual(undone.narrations.first?.filename, changed.filename)
                let asset = try XCTUnwrap(undone.availableAudioAssets.first { $0.id == changed.assetID })
                XCTAssertEqual(asset.origin, .generated)
                XCTAssertEqual(asset.customVoice, changed.customVoice)
                let reused = try AudioLayerEditor.place(assetID: asset.id, in: undone, startTime: 1)
                let savedReuse = try store.saveProject(reused, expectedRevision: undone.revision)
                XCTAssertEqual(store.project(id: project.id)?.narrations.last?.customVoice, changed.customVoice)
                let copied = try await store.duplicateProject(projectID: project.id, expectedRevision: savedReuse.revision)
                XCTAssertEqual(copied.narrations.map(\.customVoice), savedReuse.narrations.map(\.customVoice))
                XCTAssertTrue(store.voiceProfiles.isEmpty)
                XCTAssertNil(store.externalControlPrompt)
                XCTAssertNil(store.permissionPrompt)
            }
        }
    }

    func test_customVoice_invalidInputsRejectBeforeWorkAndLegacyOnlyAllowsRemoval() async throws {
        try await withClient { client, store, project, _, custom in
            let before = store.projects
            let base: [String: Value] = ["project_id": .string(project.id.uuidString), "text": "Synthetic"]
            for extra: [String: Value] in [
                [:], ["instruct": "No speaker"], ["speaker": "unknown"],
                ["speaker": "sohee", "voice_profile_id": .string(store.voiceProfiles[0].id.uuidString)],
                ["voice_profile_id": .string(store.voiceProfiles[0].id.uuidString), "instruct": ""],
                ["speaker": "sohee", "instruct": true],
            ] {
                let result = try await client.callTool(name: "storybird_start_narration_draft",
                                                     arguments: base.merging(extra) { _, value in value })
                XCTAssertEqual(result.isError, true)
                XCTAssertEqual(store.projects, before)
            }
            for name in ["storybird_select_voice_model", "storybird_prepare_voice_model"] {
                let result = try await client.callTool(name: name, arguments: [
                    "model_id": .string(VoiceModel.base0_6B.rawValue),
                ])
                XCTAssertEqual(result.isError, true)
            }
            let removal = try await client.callTool(name: "storybird_remove_voice_model", arguments: [
                "model_id": .string(VoiceModel.base0_6B.rawValue),
            ])
            XCTAssertNotEqual(removal.isError, true)
            let removed = try await poll(client, model: .base0_6B)
            XCTAssertEqual(removed.state, "not_prepared")
            let calls = await custom.generationCalls
            XCTAssertEqual(calls, 0)
        }
    }

    /// Waits only for the synthetic job's terminal state through the public MCP path.
    private func pollDraft(_ client: Client, projectID: UUID, draftID: UUID) async throws -> NarrationDraft {
        for _ in 0..<200 {
            let draft: NarrationDraft = try decode(try await client.callTool(
                name: "storybird_get_narration_draft", arguments: [
                    "project_id": .string(projectID.uuidString), "draft_id": .string(draftID.uuidString),
                ]))
            if draft.state != .generating { return draft }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CustomVoiceDraftTimeout", code: 1)
    }

    func test_removeWorkflow_preservesReadyDraftProjectsProfilesAndUndoInBothProfiles() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: profile) { client, store, project, large, _ in
                let tools = try await client.listTools().tools
                let tool = try XCTUnwrap(tools.first {
                    $0.name == "storybird_remove_voice_model"
                })
                XCTAssertEqual(tool.annotations.destructiveHint, true)
                XCTAssertEqual(tool.annotations.idempotentHint, true)
                XCTAssertEqual(tool.annotations.openWorldHint, false)
                let args: [String: Value] = ["model_id": .string(VoiceModel.base1_7B.rawValue)]
                let draftResult = try await client.callTool(name: "storybird_start_narration_draft", arguments: [
                    "project_id": .string(project.id.uuidString),
                    "voice_profile_id": .string(store.voiceProfiles[0].id.uuidString),
                    "text": "Synthetic preserved narration", "language": "english",
                ])
                var draft: NarrationDraft = try decode(draftResult)
                for _ in 0..<200 {
                    if draft.state != .generating { break }
                    try await Task.sleep(for: .milliseconds(10))
                    draft = try XCTUnwrap(store.project(id: project.id)?.narrationDrafts.first { $0.id == draft.id })
                }
                XCTAssertEqual(draft.state, .ready)
                let audioURL = store.repository.assetURL(projectID: project.id, filename: draft.filename)
                let audio = try Data(contentsOf: audioURL)
                var edited = try XCTUnwrap(store.project(id: project.id))
                edited.name = "Renamed before model removal"
                _ = try store.saveProject(edited, expectedRevision: edited.revision)
                let before = store.projects
                let profiles = store.voiceProfiles
                await large.suspendRemoval()
                let removing: VoiceModelSnapshot = try decode(try await client.callTool(
                    name: "storybird_remove_voice_model", arguments: args))
                XCTAssertEqual(removing.state, "removing")
                let repeated: VoiceModelSnapshot = try decode(try await client.callTool(
                    name: "storybird_remove_voice_model", arguments: args))
                XCTAssertEqual(repeated.state, "removing")
                let blocked = try await client.callTool(name: "storybird_start_narration_draft", arguments: [
                    "project_id": .string(project.id.uuidString),
                    "voice_profile_id": .string(profiles[0].id.uuidString),
                    "text": "Blocked", "language": "english",
                ])
                XCTAssertEqual(blocked.isError, true)
                XCTAssertEqual(store.projects, before)
                await large.finishRemoval()
                let removedState = try await poll(client, model: .base1_7B)
                XCTAssertEqual(removedState.state, "not_prepared")
                XCTAssertEqual(store.projects, before)
                XCTAssertEqual(store.voiceProfiles, profiles)
                XCTAssertEqual(try Data(contentsOf: audioURL), audio)
                XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
                XCTAssertNil(store.externalControlPrompt)
                XCTAssertNil(store.permissionPrompt)
                let undone = try store.undo(projectID: project.id, expectedRevision: 1)
                XCTAssertEqual(undone.name, project.name)
                let redone = try store.redo(projectID: project.id, expectedRevision: undone.revision)
                XCTAssertEqual(redone.name, edited.name)
                let placed = try await store.placeNarrationDraft(
                    projectID: project.id, draftID: draft.id, expectedRevision: redone.revision, startTime: 0)
                XCTAssertEqual(placed.narrations.count, 1)
                XCTAssertEqual(try Data(contentsOf: audioURL), audio)
                _ = try await client.callTool(name: "storybird_remove_voice_model", arguments: args)
                let repeatedState = try await poll(client, model: .base1_7B)
                XCTAssertEqual(repeatedState.state, "not_prepared")
                _ = try await client.callTool(name: "storybird_prepare_voice_model", arguments: args)
                let installedState = try await poll(client, model: .base1_7B)
                XCTAssertEqual(installedState.state, "ready")
            }
        }
    }

    func test_modelWorkflow_discoversSelectsPreparesAndGeneratesWithoutNativeApproval() async throws {
        try await withClient(includeVoiceProfile: false) { client, store, project, large, small in
            let tools = try await client.listTools().tools
            let prepare = try XCTUnwrap(tools.first { $0.name == "storybird_prepare_voice_model" })
            XCTAssertEqual(prepare.annotations.openWorldHint, true)
            XCTAssertEqual(prepare.annotations.destructiveHint, false)
            let list = try await client.callTool(name: "storybird_list_voice_models")
            let models: [VoiceModelSnapshot] = try decode(list)
            XCTAssertEqual(models.count, 2)
            XCTAssertTrue(models.allSatisfy { $0.quantizationBits == 8 })
            XCTAssertEqual(models.first(where: \.selected)?.id, VoiceModel.base1_7B.rawValue)
            let arguments: [String: Value] = ["model_id": .string(VoiceModel.customVoice1_7B.rawValue)]
            let selected = try await client.callTool(name: "storybird_select_voice_model", arguments: arguments)
            XCTAssertNotEqual(selected.isError, true)
            XCTAssertEqual(store.selectedVoiceModel, .customVoice1_7B)
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
            let ready = try await poll(client, model: .customVoice1_7B)
            XCTAssertEqual(ready.state, "ready")
            XCTAssertEqual(store.projects, before)
            XCTAssertNil(store.externalControlPrompt)
            XCTAssertNil(store.permissionPrompt)
            let preparedCalls = await small.prepareCalls
            XCTAssertEqual(preparedCalls, 1)

            let generated = try await client.callTool(name: "storybird_start_narration_draft", arguments: [
                "project_id": .string(project.id.uuidString),
                "speaker": .string("sohee"),
                "instruct": .string("Warm, calm narration."),
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
            for name in ["storybird_get_voice_model", "storybird_select_voice_model", "storybird_prepare_voice_model", "storybird_remove_voice_model"] {
                for arguments: [String: Value] in [
                    ["model_id": .string("unapproved-model")],
                    ["model_id": true],
                    ["model_id": .string(VoiceModel.customVoice1_7B.rawValue), "approve": true],
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
            let arguments: [String: Value] = ["model_id": .string(VoiceModel.customVoice1_7B.rawValue)]
            let before = store.projects
            _ = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            await small.finishPreparation(fail: true)
            let failed = try await poll(client, model: .customVoice1_7B)
            XCTAssertEqual(failed.state, "failed")
            XCTAssertNotNil(failed.error)
            XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
            XCTAssertEqual(store.projects, before)
            await small.allowSuccess()
            _ = try await client.callTool(name: "storybird_prepare_voice_model", arguments: arguments)
            let ready = try await poll(client, model: .customVoice1_7B)
            XCTAssertEqual(ready.state, "ready")
            XCTAssertFalse(ready.selected)
            XCTAssertEqual(store.project(id: project.id)?.revision, 0)
            XCTAssertNil(store.externalControlPrompt)
            let calls = await small.prepareCalls
            XCTAssertEqual(calls, 2)
        }
    }

    /// Stops polling when installation or removal reaches a terminal state.
    private func poll(_ client: Client, model: VoiceModel) async throws -> VoiceModelSnapshot {
        for _ in 0..<200 {
            let result = try await client.callTool(name: "storybird_get_voice_model",
                                                 arguments: ["model_id": .string(model.rawValue)])
            let snapshot: VoiceModelSnapshot = try decode(result)
            if snapshot.state != "preparing", snapshot.state != "removing" { return snapshot }
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

    /// Exercises production MCP handlers against a temporary app host. An empty
    /// profile list verifies that CustomVoice needs no native profile setup.
    private func withClient(
        profile: StorybirdMCPToolProfile = .legacy,
        includeVoiceProfile: Bool = true,
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
        if includeVoiceProfile { try repository.saveVoiceProfiles([VoiceProfile(name: "Synthetic", referenceFilename: "reference.wav",
                                                       referenceText: "Synthetic reference", consentConfirmed: true)]) }
        let large = ModelTestProvider(ready: true)
        let small = ModelTestProvider(hold: true)
        let store = AppStore(repository: repository,
                             voiceModelServices: [.base1_7B: large, .customVoice1_7B: small])
        let host = StorybirdExternalControlHost(store: store)
        let ipc = StorybirdAppIPCClient(sender: { await host.handle($0) },
                                       launcher: { throw NSError(domain: "UnexpectedAppLaunch", code: 1) })
        let server = await StorybirdMCPService(client: ipc, toolProfile: profile).makeServer()
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
