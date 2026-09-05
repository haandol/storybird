import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class AppStoreTests: XCTestCase {
    func test_replaceProject_identicalValueLeavesLibraryUnchanged() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Existing project")
        try repository.saveProjects([project])
        let libraryURL = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: libraryURL)
        let store = AppStore(repository: repository)
        let loadedProject = try XCTUnwrap(store.project(id: project.id))

        store.replaceProject(loadedProject)

        XCTAssertEqual(
            store.project(id: project.id)?.updatedAt,
            loadedProject.updatedAt
        )
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
    }

    func test_replaceProject_invalidVideoLayer_preservesStoredProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var invalid = project
        invalid.clicks = [
            TimedPointerClick(time: 10, x: 0.5, y: 0.5),
        ]

        store.replaceProject(invalid)

        XCTAssertNotNil(store.errorMessage)
        let stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.id, project.id)
        XCTAssertEqual(stored.recording, project.recording)
        XCTAssertEqual(stored.clicks, project.clicks)
        XCTAssertEqual(try repository.loadProjects().first?.clicks, project.clicks)
    }

    func test_externalControl_updateProject_usesAppStoreWriter() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "name": "After",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_project",
                argumentsJSON: arguments
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertEqual(store.project(id: project.id)?.name, "After")
        XCTAssertEqual(
            try repository.loadProjects().first?.name,
            "After"
        )
    }

    func test_saveProject_staleRevisionPreservesLatestProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var first = project
        first.name = "First"
        let saved = try store.saveProject(first, expectedRevision: 0)
        var stale = project
        stale.name = "Stale"

        XCTAssertThrowsError(
            try store.saveProject(stale, expectedRevision: 0)
        )
        XCTAssertEqual(store.project(id: project.id)?.name, "First")
        XCTAssertEqual(store.project(id: project.id)?.revision, saved.revision)
    }

    func test_externalControl_replaceProject_enforcesExpectedRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        var replacement = project
        replacement.summary = "Edited through MCP"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(
            decoding: try encoder.encode(replacement),
            as: UTF8.self
        )
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "project_json": json,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_replace_project",
                argumentsJSON: arguments
            )
        )
        let stale = await host.handle(
            StorybirdControlRequest(
                name: "storybird_replace_project",
                argumentsJSON: arguments
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertTrue(stale.isError)
        XCTAssertEqual(
            store.project(id: project.id)?.summary,
            "Edited through MCP"
        )
        XCTAssertEqual(store.project(id: project.id)?.revision, 1)
    }

    func test_undoRedo_restoresWholeProjectWithMonotonicRevision() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = project
        edited.name = "After"
        let saved = try store.saveProject(edited, expectedRevision: 0)

        let undone = try store.undo(projectID: project.id)
        let redone = try store.redo(projectID: project.id)

        XCTAssertEqual(undone.name, "Before")
        XCTAssertEqual(redone.name, "After")
        XCTAssertGreaterThan(undone.revision, saved.revision)
        XCTAssertGreaterThan(redone.revision, undone.revision)
    }

    func test_saveProject_terminalSuggestionCannotReturnToPending() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.suggestions = ClickSuggestionGenerator.generate(for: project)
        project.suggestions[0].state = .rejected
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var invalid = project
        invalid.suggestions[0].state = .pending

        XCTAssertThrowsError(
            try store.saveProject(invalid, expectedRevision: 0)
        )
        XCTAssertEqual(
            store.project(id: project.id)?.suggestions[0].state,
            .rejected
        )
    }

    func test_externalControl_invalidExportDoesNotCreateJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "parent_directory": root.path,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_start_export",
                argumentsJSON: arguments
            )
        )

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("Click Cues"))
    }

    func test_referenceProject_95PercentOfEditsPersistWithin500Milliseconds() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let recording = VideoRecordingAsset(
            filename: "recording.mp4",
            duration: 120,
            width: 1_920,
            height: 1_080
        )
        let subtitles = (0..<100).map { index in
            TimedSubtitle(
                startTime: Double(index),
                endTime: Double(index) + 0.5,
                text: "Layer \(index)"
            )
        }
        let project = DemoProject(
            name: "Reference",
            recording: recording,
            subtitles: subtitles
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var withinTarget = 0

        for index in 0..<100 {
            var edited = try XCTUnwrap(store.project(id: project.id))
            edited.summary = "Edit \(index)"
            let started = ContinuousClock.now
            _ = try store.saveProject(
                edited,
                expectedRevision: edited.revision
            )
            if started.duration(to: .now) <= .milliseconds(500) {
                withinTarget += 1
            }
        }

        XCTAssertGreaterThanOrEqual(withinTarget, 95)
    }

    func test_invalidProjectMutations_twentyOfTwentyPreserveStoredProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let baseline = try XCTUnwrap(store.project(id: project.id))

        for index in 0..<20 {
            var invalid = baseline
            invalid.clicks[0].x = 2 + Double(index)
            XCTAssertThrowsError(
                try store.saveProject(invalid, expectedRevision: 0)
            )
            XCTAssertEqual(store.project(id: project.id), baseline)
            XCTAssertEqual(try repository.loadProjects().first, baseline)
        }
    }

    func test_externalControl_invalidClickEdit_returnsErrorAndPreservesProject() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "click_id": project.clicks[0].id.uuidString,
                "x": 2,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_click",
                argumentsJSON: arguments
            )
        )

        XCTAssertTrue(response.isError)
        XCTAssertEqual(store.project(id: project.id)?.clicks, project.clicks)
        XCTAssertEqual(
            try repository.loadProjects().first?.clicks,
            project.clicks
        )
    }

    func test_externalControl_updateClick_returnsNewRevisionAndTargetID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "click_id": project.clicks[0].id.uuidString,
                "caption": "Updated caption",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_update_click",
                argumentsJSON: arguments
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(response.text.utf8)
            ) as? [String: Any]
        )
        let value = try XCTUnwrap(payload["value"] as? [String: Any])
        let description = try XCTUnwrap(
            value["description"] as? [String: Any]
        )

        XCTAssertFalse(response.isError)
        XCTAssertEqual(payload["revision"] as? Int, 1)
        XCTAssertEqual(
            payload["target_id"] as? String,
            project.clicks[0].id.uuidString
        )
        XCTAssertEqual(description["text"] as? String, "Updated caption")
    }

    func test_externalControl_upsertSubtitle_usesProjectTimelineAndReturnsRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.clips[0].playbackRate = 0.5
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "start_time": 6.0,
                "end_time": 7.0,
                "text": "Edited timeline subtitle",
                "position": "top",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_upsert_subtitle",
                argumentsJSON: arguments
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(response.text.utf8)
            ) as? [String: Any]
        )
        let stored = try XCTUnwrap(store.project(id: project.id))

        XCTAssertFalse(response.isError)
        XCTAssertEqual(payload["revision"] as? Int, 1)
        XCTAssertEqual(stored.subtitles.count, 1)
        XCTAssertEqual(stored.subtitles[0].startTime, 6)
        XCTAssertEqual(stored.subtitles[0].endTime, 7)
        XCTAssertEqual(
            payload["target_id"] as? String,
            stored.subtitles[0].id.uuidString
        )
    }

    func test_commitRecordedVideo_preservesAcceptedClickOrder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        let first = TimedPointerClick(time: 1, x: 0.2, y: 0.3)
        let second = TimedPointerClick(time: 1, x: 0.8, y: 0.7)
        let third = TimedPointerClick(time: 2, x: 0.4, y: 0.6)
        try store.commitRecordedVideo(
            projectID: projectID,
            name: "Recorded",
            filename: target.filename,
            result: ScreenVideoRecordingResult(
                duration: 3,
                width: 640,
                height: 480
            ),
            clicks: [first, second, third]
        )

        let project = try XCTUnwrap(store.project(id: projectID))
        XCTAssertEqual(project.recording?.filename, target.filename)
        XCTAssertEqual(project.clicks.map(\.id), [
            first.id,
            second.id,
            third.id,
        ])
        XCTAssertEqual(store.selectedProjectID, projectID)
        XCTAssertEqual(try repository.loadProjects().first?.id, projectID)
    }

    func test_commitRecordedVideo_invalidTimeline_removesUnpublishedAssets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let existing = DemoProject(name: "Existing")
        try repository.saveProjects([existing])
        let store = AppStore(repository: repository)
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        XCTAssertThrowsError(
            try store.commitRecordedVideo(
                projectID: projectID,
                name: "Invalid",
                filename: target.filename,
                result: ScreenVideoRecordingResult(
                    duration: 1,
                    width: 640,
                    height: 480
                ),
                clicks: [
                    TimedPointerClick(time: 2, x: 0.5, y: 0.5),
                ]
            )
        )

        XCTAssertEqual(store.projects.map(\.id), [existing.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.assetsDirectory(
                    projectID: projectID
                ).path
            )
        )
    }

    func test_commitRecordedVideo_librarySaveFailure_removesVideoAndKeepsLibraryEmpty() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository)
        let libraryURL = root.appendingPathComponent(
            "library.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        let projectID = UUID()
        let target = try repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        try Data("video".utf8).write(to: target.url)

        XCTAssertThrowsError(
            try store.commitRecordedVideo(
                projectID: projectID,
                name: "Save failure",
                filename: target.filename,
                result: ScreenVideoRecordingResult(
                    duration: 1,
                    width: 640,
                    height: 480
                ),
                clicks: []
            )
        )

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.assetsDirectory(
                    projectID: projectID
                ).path
            )
        )
    }

    func test_externalControlApproval_requiresNativeResolution() async {
        let store = AppStore(
            repository: ProjectRepository(rootURL: temporaryDirectory())
        )
        let decision = Task { @MainActor in
            await store.requestExternalControlApproval(
                title: "Allow?",
                message: "Synthetic approval"
            )
        }
        await Task.yield()

        XCTAssertNotNil(store.externalControlPrompt)
        store.resolveExternalControlApproval(true)
        let allowed = await decision.value

        XCTAssertTrue(allowed)
        XCTAssertNil(store.externalControlPrompt)
    }

    func test_externalAbort_cancelsPendingNativeApproval() async {
        let store = AppStore(
            repository: ProjectRepository(rootURL: temporaryDirectory())
        )
        let host = StorybirdExternalControlHost(store: store)
        let decision = Task { @MainActor in
            await store.requestExternalControlApproval(
                title: "Allow?",
                message: "Synthetic approval"
            )
        }
        await Task.yield()

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_abort_session",
                argumentsJSON: Data("{}".utf8)
            )
        )
        let allowed = await decision.value

        XCTAssertFalse(response.isError)
        XCTAssertFalse(allowed)
        XCTAssertNil(store.externalControlPrompt)
    }

    private func validVideoProject() -> DemoProject {
        DemoProject(
            name: "Video",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 640,
                height: 480
            ),
            clicks: [
                TimedPointerClick(time: 1, x: 0.5, y: 0.5),
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
