import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPRecordingApprovalTests: XCTestCase {
    func test_settings_uiAndMCPSharePersistentValueWithoutProjectEdits() async throws {
        try await withClient { client, store, platform, defaults in
            let before = store.projects
            try await assertSetting(client, enabled: false)
            store.setAutomaticallyApprovesMCPRecording(true)
            try await assertSetting(client, enabled: true)
            for _ in 0..<2 {
                try await set(client, enabled: true)
            }
            let restored = AppStore(repository: store.repository,
                                    recordingPreferences: StorybirdRecordingPreferences(defaults: defaults))
            XCTAssertTrue(restored.automaticallyApprovesMCPRecording)
            XCTAssertTrue(defaults.synchronize())
            // macOS manages the on-disk flush. Read the persisted domain from
            // another process, rather than assuming the backing file is current.
            let reader = Process()
            let output = Pipe()
            reader.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            reader.arguments = ["export", try XCTUnwrap(defaults.string(forKey: "testDomain")), "-"]
            reader.standardOutput = output
            try reader.run()
            let plist = output.fileHandleForReading.readDataToEndOfFile()
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0)
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
            XCTAssertEqual(values["storybird.mcpRecordingAutoApproval"] as? Bool, true)

            try await set(client, enabled: false)
            XCTAssertFalse(store.automaticallyApprovesMCPRecording)
            let reopened = AppStore(repository: store.repository,
                                    recordingPreferences: StorybirdRecordingPreferences(defaults: defaults))
            XCTAssertFalse(reopened.automaticallyApprovesMCPRecording)
            XCTAssertEqual(store.projects, before)
            XCTAssertNil(store.externalControlPrompt)
            let starts = await platform.starts
            XCTAssertEqual(starts, 0)
        }
    }

    func test_defaultApproval_declineDoesNotCaptureAndAcceptCompletesProject() async throws {
        try await withClient { client, store, platform, _ in
            let declined = Task { try await start(client) }
            try await waitForPrompt(store)
            XCTAssertTrue(store.externalControlPrompt?.message.contains("Synthetic window") == true)
            let startsBeforeConsent = await platform.starts
            XCTAssertEqual(startsBeforeConsent, 0)
            store.resolveExternalControlApproval(false)
            let rejected = try await declined.value
            XCTAssertEqual(rejected.isError, true)
            XCTAssertTrue(store.projects.isEmpty)

            let accepted = Task { try await start(client) }
            try await waitForPrompt(store)
            store.resolveExternalControlApproval(true)
            let started = try await accepted.value
            XCTAssertNotEqual(started.isError, true)
            let stopped = try await client.callTool(name: "storybird_stop_session")
            XCTAssertNotEqual(stopped.isError, true)
            XCTAssertEqual(store.projects.count, 1)
            XCTAssertNil(store.storageChangeDisabledReason)
        }
    }

    func test_autoApproval_recordsAndControlsThenDisablingRestoresNextSessionPrompt() async throws {
        try await withClient { client, store, platform, _ in
            try await set(client, enabled: true)
            let started = try await start(client)
            XCTAssertNotEqual(started.isError, true)
            XCTAssertNil(store.externalControlPrompt)
            XCTAssertTrue(started.content.contains { if case .image = $0 { return true }; return false })
            let duplicate = try await start(client)
            XCTAssertEqual(duplicate.isError, true)
            let invalidClick = try await client.callTool(name: "storybird_click", arguments: [
                "x": 1.1, "y": 0.5,
            ])
            XCTAssertEqual(invalidClick.isError, true)
            let inputsBeforeValidClick = await platform.desktop.inputCount
            XCTAssertEqual(inputsBeforeValidClick, 0)
            try await set(client, enabled: false)
            let observed = try await client.callTool(name: "storybird_observe")
            XCTAssertNotEqual(observed.isError, true, "Changing the preference must not terminate active capture.")
            let clicked = try await client.callTool(name: "storybird_click", arguments: ["x": 0.5, "y": 0.5])
            XCTAssertNotEqual(clicked.isError, true)
            let stopped = try await client.callTool(name: "storybird_stop_session")
            XCTAssertNotEqual(stopped.isError, true)
            XCTAssertEqual(store.projects.count, 1)
            XCTAssertEqual(store.projects.first?.clicks.count, 1)
            let afterStop = try await client.callTool(name: "storybird_click", arguments: ["x": 0.5, "y": 0.5])
            XCTAssertEqual(afterStop.isError, true)
            let inputs = await platform.desktop.inputCount
            XCTAssertEqual(inputs, 1)
            let next = Task { try await start(client) }
            try await waitForPrompt(store)
            store.resolveExternalControlApproval(false)
            let rejected = try await next.value
            XCTAssertEqual(rejected.isError, true)
            XCTAssertEqual(store.projects.count, 1)
            let starts = await platform.starts
            XCTAssertEqual(starts, 1)
        }
    }

    func test_pendingConsent_settingChangeDoesNotAcceptOrOvertakePrompt() async throws {
        try await withClient { client, store, platform, _ in
            let pending = Task { try await start(client) }
            try await waitForPrompt(store)
            let promptID = store.externalControlPrompt?.id
            store.setAutomaticallyApprovesMCPRecording(true)
            XCTAssertEqual(store.externalControlPrompt?.id, promptID)
            let overtaking = await store.requestRecordingControlApproval(sourceTitle: "Another source")
            XCTAssertFalse(overtaking)
            let starts = await platform.starts
            XCTAssertEqual(starts, 0)
            store.cancelExternalControlApproval()
            let result = try await pending.value
            XCTAssertEqual(result.isError, true)
            let fresh = try await start(client)
            XCTAssertNotEqual(fresh.isError, true)
            let aborted = try await client.callTool(name: "storybird_abort_session")
            XCTAssertNotEqual(aborted.isError, true)
            let observed = try await client.callTool(name: "storybird_observe")
            XCTAssertEqual(observed.isError, true)
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertNil(store.storageChangeDisabledReason)
        }
    }

    func test_autoApproval_doesNotBypassPermissionsMissingSourcesOrMicrophoneLease() async throws {
        try await withClient { client, store, platform, _ in
            try await set(client, enabled: true)
            let missing = try await client.callTool(name: "storybird_start_session", arguments: [
                "source_id": "missing", "project_name": "Invalid source",
            ])
            XCTAssertEqual(missing.isError, true)
            let lease = try store.beginMicrophoneOperation()
            let busy = try await start(client)
            XCTAssertEqual(busy.isError, true)
            store.endStorageOperation(lease)
            for error in [StorybirdMCPError.screenRecordingPermission, .pointerControlPermission] {
                await platform.failStart(with: error)
                let denied = try await start(client)
                XCTAssertEqual(denied.isError, true)
                XCTAssertTrue(text(denied).contains(error.localizedDescription))
                XCTAssertNil(store.externalControlPrompt)
                XCTAssertNil(store.storageChangeDisabledReason)
                XCTAssertTrue(store.projects.isEmpty)
            }
            let inputs = await platform.desktop.inputCount
            XCTAssertEqual(inputs, 0)
            await platform.failStart(with: nil)
            let retry = try await start(client)
            XCTAssertNotEqual(retry.isError, true)
            _ = try await client.callTool(name: "storybird_abort_session")
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func test_autoApproval_permanentDeletionStillWaitsForNativeConfirmation() async throws {
        try await withClient { client, store, _, _ in
            let project = DemoProject(name: "Keep this project")
            try store.repository.saveProjects([project])
            // Reopen the same temporary library and defaults; use its production app handler.
            let reopened = AppStore(repository: store.repository)
            let beforeDeletion = reopened.projects
            reopened.setAutomaticallyApprovesMCPRecording(true)
            let host = StorybirdExternalControlHost(store: reopened)
            let deletion = Task {
                await host.handle(StorybirdControlRequest(
                    name: "storybird_delete_project",
                    argumentsJSON: try JSONSerialization.data(withJSONObject: ["project_id": project.id.uuidString])
                ))
            }
            try await waitForPrompt(reopened)
            XCTAssertEqual(reopened.externalControlPrompt?.destructive, true)
            XCTAssertEqual(reopened.projects, beforeDeletion)
            reopened.resolveExternalControlApproval(false)
            let result = try await deletion.value
            XCTAssertTrue(result.isError)
            XCTAssertEqual(try reopened.repository.loadProjects(), beforeDeletion)
            try await assertSetting(client, enabled: false)
        }
    }

    func test_invalidSettingRequests_rejectWithoutChangingPersistentValue() async throws {
        try await withClient { client, store, _, defaults in
            try await set(client, enabled: true)
            for arguments: [String: Value] in [
                [:], ["enabled": 0], ["enabled": 1], ["enabled": "false"],
                ["enabled": .null], ["enabled": .array([])], ["enabled": false, "approve": true],
            ] {
                let result = try await client.callTool(name: "storybird_set_recording_auto_approval",
                                                      arguments: arguments)
                XCTAssertEqual(result.isError, true)
                XCTAssertTrue(store.automaticallyApprovesMCPRecording)
                XCTAssertTrue(StorybirdRecordingPreferences(defaults: defaults).automaticallyApprovesMCPRecording)
            }
            let invalidGet = try await client.callTool(name: "storybird_get_recording_auto_approval",
                                                      arguments: ["enabled": false])
            XCTAssertEqual(invalidGet.isError, true)
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func test_corruptPreference_fallsBackToManualApproval() throws {
        let domain = "storybird.approval.corrupt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = StorybirdRecordingPreferences(defaults: defaults)
        XCTAssertFalse(preferences.automaticallyApprovesMCPRecording)
        for invalid in ["true", 1, ["enabled": true]] as [Any] {
            defaults.set(invalid, forKey: "storybird.mcpRecordingAutoApproval")
            XCTAssertFalse(preferences.automaticallyApprovesMCPRecording)
        }
    }

    private typealias Result = (content: [Tool.Content], isError: Bool?)

    private func start(_ client: Client) async throws -> Result {
        try await client.callTool(name: "storybird_start_session", arguments: [
            "source_id": "window-1", "project_name": "Synthetic recording",
        ])
    }

    private func set(_ client: Client, enabled: Bool) async throws {
        let result = try await client.callTool(name: "storybird_set_recording_auto_approval",
                                              arguments: ["enabled": .bool(enabled)])
        XCTAssertNotEqual(result.isError, true, text(result))
        try await assertSetting(client, enabled: enabled)
    }

    private func assertSetting(_ client: Client, enabled: Bool) async throws {
        let result = try await client.callTool(name: "storybird_get_recording_auto_approval")
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try JSONDecoder().decode([String: Bool].self, from: Data(text(result).utf8)),
                       ["enabled": enabled])
    }

    private func text(_ result: Result) -> String {
        result.content.compactMap { if case let .text(value, _, _) = $0 { return value }; return nil }.joined()
    }

    private func waitForPrompt(_ store: AppStore) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while store.externalControlPrompt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(store.externalControlPrompt, "A manual decision must appear before capture.")
    }

    /// Runs the production MCP schema, dispatch and app handler with synthetic
    /// capture only. A watchdog bounds broken approval paths instead of hanging.
    private func withClient(
        _ body: @MainActor (Client, AppStore, ApprovalTestPlatform, UserDefaults) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)")
        let domain = "storybird.approval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(domain, forKey: "testDomain")
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(repository: ProjectRepository(rootURL: root),
                             recordingPreferences: StorybirdRecordingPreferences(defaults: defaults))
        let platform = ApprovalTestPlatform()
        let host = StorybirdExternalControlHost(store: store,
                                                recordingSession: StorybirdControlSession(platform: platform))
        let ipc = StorybirdAppIPCClient(sender: { await host.handle($0) },
                                       launcher: { throw StorybirdControlWireError.invalidMessage })
        let service = StorybirdMCPService(client: ipc)
        let transport = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transport.server)
        let client = Client(name: "Recording approval test", version: "1")
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            store.cancelExternalControlApproval()
            await client.disconnect()
        }
        do {
            _ = try await client.connect(transport: transport.client)
            try await body(client, store, platform, defaults)
            deadline.cancel()
            await service.abortActiveSession()
            await client.disconnect()
            await server.stop()
        } catch {
            deadline.cancel()
            await service.abortActiveSession()
            await client.disconnect()
            await server.stop()
            throw error
        }
    }
}

private actor ApprovalTestPlatform: StorybirdDesktopPlatform {
    let desktop = ApprovalTestDesktop()
    private(set) var starts = 0
    private var failure: StorybirdMCPError?

    func failStart(with error: StorybirdMCPError?) { failure = error }
    func listSources() async throws -> [StorybirdMCPSourceDescriptor] {
        [await desktop.sourceDescriptor()]
    }
    func startSession(sourceID: String, recordingURL: URL) async throws -> any StorybirdDesktopSession {
        if let failure { throw failure }
        starts += 1
        let result = try await TestVideoFactory.makeMovie(at: recordingURL, includeAudio: false)
        await desktop.setRecording(result)
        return desktop
    }
}

private actor ApprovalTestDesktop: StorybirdDesktopSession {
    private(set) var inputCount = 0
    private var recording: StorybirdMCPVideoRecording?

    func setRecording(_ result: ScreenVideoRecordingResult) {
        recording = StorybirdMCPVideoRecording(duration: result.duration, width: result.width, height: result.height)
    }
    func sourceDescriptor() async -> StorybirdMCPSourceDescriptor {
        StorybirdMCPSourceDescriptor(id: "window-1", kind: .window, title: "Synthetic window",
                                    subtitle: "Test only", width: 100, height: 100)
    }
    func latestFrame() async throws -> StorybirdMCPFrame {
        StorybirdMCPFrame(pngData: Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!,
                         width: 1, height: 1)
    }
    func movePointer(x: Double, y: Double, durationMilliseconds: Int) async throws -> StorybirdMCPFrame {
        inputCount += 1
        return try await latestFrame()
    }
    func click(x: Double, y: Double, button: StorybirdMCPPointerButton) async throws -> StorybirdMCPClickResult {
        inputCount += 1
        return StorybirdMCPClickResult(frame: try await latestFrame(), recordingTime: 0.25, observedFreshFrame: true)
    }
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws -> StorybirdMCPFrame {
        inputCount += 1
        return try await latestFrame()
    }
    func stop() async throws -> StorybirdMCPVideoRecording { try XCTUnwrap(recording) }
    func abort() async {}
}
