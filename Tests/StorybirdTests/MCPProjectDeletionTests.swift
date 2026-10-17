import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPProjectDeletionTests: XCTestCase {
    private typealias ProtocolResult = (content: [Tool.Content], isError: Bool?)
    func test_agentConfirmation_bothProfilesDeleteOnlyOwnedAssetsWithoutPrompt() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: profile) { client, store, project, assets, external, _ in
                let beforeOther = store.projects.last!
                let protected = ["Voices/profile.wav", "VoiceRuntime/model.bin", "export.mp4"].map {
                    store.repository.rootURL.appendingPathComponent($0)
                }
                for url in protected {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try Data("preserve".utf8).write(to: url)
                }
                try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("external-link"),
                    withDestinationURL: protected[0].deletingLastPathComponent())
                let result = try await client.callTool(name: "storybird_delete_project", arguments: [
                    "project_id": .string(project.id.uuidString), "confirmed": true,
                    "expected_revision": .int(project.revision),
                ])
                XCTAssertNotEqual(result.isError, true)
                let deletion = try decode(result)
                XCTAssertEqual(deletion.status, "deleted")
                XCTAssertTrue(deletion.projectRemoved)
                XCTAssertTrue(deletion.assetsRemoved)
                XCTAssertNil(store.project(id: project.id))
                XCTAssertEqual(store.project(id: beforeOther.id), beforeOther)
                XCTAssertNil(store.externalControlPrompt)
                XCTAssertFalse(FileManager.default.fileExists(atPath: assets.path))
                XCTAssertEqual(try Data(contentsOf: external), Data("external-original".utf8))
                for url in protected { XCTAssertEqual(try Data(contentsOf: url), Data("preserve".utf8)) }
                XCTAssertEqual(try store.repository.loadProjects(), [beforeOther])
                XCTAssertThrowsError(try store.undo(projectID: project.id))
                XCTAssertFalse(store.automaticallyApprovesMCPRecording)
            }
        }
    }

    func test_declinedAndInvalidConfirmation_bothProfilesKeepProjectWithoutPrompt() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: profile) { client, store, project, assets, _, _ in
                let cancelled = try await client.callTool(name: "storybird_delete_project", arguments: [
                    "project_id": .string(project.id.uuidString), "confirmed": false,
                ])
                XCTAssertEqual(try decode(cancelled).status, "cancelled")
                for extras: [String: Value] in [
                    ["confirmed": true],
                    ["confirmed": "true", "expected_revision": 0],
                    ["confirmed": 1, "expected_revision": 0],
                    ["confirmed": true, "expected_revision": true],
                    ["confirmed": true, "expected_revision": 0.5],
                    ["confirmed": true, "expected_revision": -1],
                    ["confirmed": true, "expected_revision": 0, "force": true],
                ] {
                    var arguments = extras
                    arguments["project_id"] = .string(project.id.uuidString)
                    let result = try await client.callTool(name: "storybird_delete_project", arguments: arguments)
                    XCTAssertEqual(result.isError, true, "\(extras)")
                    XCTAssertEqual(store.project(id: project.id), project)
                    XCTAssertNil(store.externalControlPrompt)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
                }
            }
        }
    }

    func test_staleConfirmation_reportsCurrentRevisionAndPreservesProject() async throws {
        try await withClient { client, store, project, assets, _, _ in
            var changed = project
            changed.name = "Newer user edit"
            let current = try store.saveProject(changed, expectedRevision: project.revision)
            let result = try await client.callTool(name: "storybird_delete_project", arguments: [
                "project_id": .string(project.id.uuidString), "confirmed": true,
                "expected_revision": .int(project.revision),
            ])
            XCTAssertEqual(result.isError, true)
            let deletion = try decode(result)
            XCTAssertEqual(deletion.code, "revision_conflict")
            XCTAssertEqual(deletion.currentRevision, current.revision)
            XCTAssertFalse(deletion.projectRemoved)
            XCTAssertEqual(store.project(id: project.id), current)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
            XCTAssertNil(store.externalControlPrompt)
        }
    }

    func test_nativeConfirmation_rechecksRevisionAfterUserWait() async throws {
        try await withClient { client, store, project, assets, _, _ in
            let pending = Task {
                try await client.callTool(name: "storybird_delete_project",
                    arguments: ["project_id": .string(project.id.uuidString)])
            }
            try await waitForPrompt(store)
            var changed = project
            changed.name = "Edited while prompt was open"
            let current = try store.saveProject(changed, expectedRevision: project.revision)
            store.resolveExternalControlApproval(true)
            let result = try await pending.value
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(try decode(result).code, "revision_conflict")
            XCTAssertEqual(store.project(id: project.id), current)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
        }
    }

    func test_nativeConfirmation_retainsLegacySuccessResponse() async throws {
        try await withClient { client, store, project, assets, _, _ in
            let pending = Task {
                try await client.callTool(name: "storybird_delete_project",
                    arguments: ["project_id": .string(project.id.uuidString)])
            }
            try await waitForPrompt(store)
            XCTAssertNotNil(store.project(id: project.id))
            store.resolveExternalControlApproval(true)
            let result = try await pending.value
            XCTAssertNotEqual(result.isError, true)
            XCTAssertEqual(text(result), "Project deleted.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: assets.path))
        }
    }

    func test_indexWriteFailure_reportsFailureWithoutRemovingProjectOrAssets() async throws {
        try await withClient { client, store, project, assets, _, manager in
            let before = try Data(contentsOf: store.repository.rootURL.appendingPathComponent("library.json"))
            manager.failure = .prepare
            let result = try await confirmedDelete(client, project)
            XCTAssertEqual(result.isError, true)
            let deletion = try decode(result)
            XCTAssertEqual(deletion.code, "index_write_failed")
            XCTAssertFalse(deletion.projectRemoved)
            XCTAssertFalse(deletion.assetsRemoved)
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
            XCTAssertEqual(try Data(contentsOf: store.repository.rootURL.appendingPathComponent("library.json")), before)
        }
    }

    func test_nativeCleanupFailure_reportsPartialOutcome() async throws {
        try await withClient { client, store, project, assets, _, manager in
            let pending = Task {
                try await client.callTool(name: "storybird_delete_project",
                    arguments: ["project_id": .string(project.id.uuidString)])
            }
            try await waitForPrompt(store)
            manager.failure = .removeAssets
            store.resolveExternalControlApproval(true)
            let result = try await pending.value
            XCTAssertEqual(result.isError, true)
            let deletion = try decode(result)
            XCTAssertEqual(deletion.code, "asset_cleanup_failed")
            XCTAssertTrue(deletion.projectRemoved)
            XCTAssertFalse(deletion.assetsRemoved)
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
        }
    }

    func test_nativeTargetRemovedDuringConfirmation_doesNotDeleteAnotherProject() async throws {
        try await withClient { client, store, project, _, _, _ in
            let pending = Task {
                try await client.callTool(name: "storybird_delete_project",
                    arguments: ["project_id": .string(project.id.uuidString)])
            }
            try await waitForPrompt(store)
            XCTAssertEqual(store.deleteProject(id: project.id).status, "deleted")
            let remaining = store.projects
            store.resolveExternalControlApproval(true)
            let result = try await pending.value
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(try decode(result).code, "project_not_found")
            XCTAssertEqual(store.projects, remaining)
            XCTAssertEqual(try store.repository.loadProjects(), remaining)
        }
    }

    func test_assetCleanupFailure_reportsPartialOutcomeWithoutClaimingSuccess() async throws {
        try await withClient { client, store, project, assets, external, manager in
            manager.failure = .removeAssets
            let result = try await confirmedDelete(client, project)
            XCTAssertEqual(result.isError, true)
            let deletion = try decode(result)
            XCTAssertEqual(deletion.code, "asset_cleanup_failed")
            XCTAssertTrue(deletion.projectRemoved)
            XCTAssertFalse(deletion.assetsRemoved)
            XCTAssertNil(store.project(id: project.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
            XCTAssertFalse(try store.repository.loadProjects().contains { $0.id == project.id })
        }
    }

    private func confirmedDelete(_ client: Client, _ project: DemoProject) async throws -> ProtocolResult {
        try await client.callTool(name: "storybird_delete_project", arguments: [
            "project_id": .string(project.id.uuidString), "confirmed": true,
            "expected_revision": .int(project.revision),
        ])
    }

    private func text(_ result: ProtocolResult) -> String {
        result.content.compactMap { if case let .text(value, _, _) = $0 { return value }; return nil }.joined()
    }

    private func decode(_ result: ProtocolResult) throws -> ProjectDeletionResult {
        try JSONDecoder().decode(ProjectDeletionResult.self, from: Data(text(result).utf8))
    }

    private func waitForPrompt(_ store: AppStore) async throws {
        for _ in 0..<200 {
            if store.externalControlPrompt != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The legacy request did not produce its native confirmation")
        throw StorybirdControlWireError.invalidMessage
    }

    /// Uses production MCP dispatch and app handlers with a disposable library.
    /// File faults are injected below the store, not substituted deletion results.
    private func withClient(
        profile: StorybirdMCPToolProfile = .legacy,
        _ body: @MainActor (Client, AppStore, DemoProject, URL, URL, DeletionFileManager) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DeletionFileManager()
        let repository = ProjectRepository(rootURL: root, fileManager: manager)
        let project = DemoProject(name: "Delete only this project")
        try repository.saveProjects([project, DemoProject(name: "Keep this project")])
        let assets = root.appendingPathComponent("Assets/\(project.id.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: assets.appendingPathComponent("owned.bin"))
        let external = root.appendingPathComponent("external.mov")
        try Data("external-original".utf8).write(to: external)
        let store = AppStore(repository: repository)
        let storedProject = try XCTUnwrap(store.project(id: project.id))
        let host = StorybirdExternalControlHost(store: store)
        let service = StorybirdMCPService(client: StorybirdAppIPCClient(sender: { await host.handle($0) },
            launcher: { throw StorybirdControlWireError.invalidMessage }), toolProfile: profile)
        let transports = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transports.server)
        let client = Client(name: "Deletion protocol test", version: "1")
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            store.cancelExternalControlApproval()
            await client.disconnect()
        }
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client, store, storedProject, assets, external, manager)
            watchdog.cancel()
            await client.disconnect()
            await server.stop()
        } catch {
            watchdog.cancel()
            store.cancelExternalControlApproval()
            await client.disconnect()
            await server.stop()
            throw error
        }
    }
}

/// Foundation can invoke file operations outside actor isolation; faults use a lock.
private final class DeletionFileManager: FileManager, @unchecked Sendable {
    enum Failure { case none, prepare, removeAssets }
    private let lock = NSLock()
    private var storedFailure = Failure.none
    var failure: Failure {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if failure == .prepare { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func removeItem(at URL: URL) throws {
        if failure == .removeAssets { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
