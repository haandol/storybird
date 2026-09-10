import Foundation
import StorybirdCore
import StorybirdMCPKit
import XCTest
@testable import Storybird

@MainActor
final class ClickTimeEditingTests: XCTestCase {
    func test_timeProperty_nativeAndMCPPreserveWindowsAndSourceAnchor() async throws {
        let (store, project) = try fixture()
        let cue = project.clicks[0]
        var edited = project
        edited.clicks[0].time = 1.1
        ProjectWorkspaceView(store: store, projectID: project.id).projectBinding(for: project).wrappedValue = edited
        let native = try XCTUnwrap(store.project(id: project.id))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(native.clicks[0].time, 1.1, accuracy: 0.0001)
        XCTAssertEqual(native.clicks[0].sourceTime, 1.1, accuracy: 0.0001)
        XCTAssertEqual(native.clicks[0].indicator, cue.indicator)
        XCTAssertEqual(native.clicks[0].description, cue.description)
        XCTAssertEqual(native.clicks[0].cueSubtitle, cue.cueSubtitle)
        _ = try store.undo(projectID: project.id)
        let before = try XCTUnwrap(store.project(id: project.id))
        let response = try await update(store, project: before, fields: ["time": 1.1])
        XCTAssertFalse(response.isError, response.text)
        let agent = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(agent.clicks, native.clicks)
        XCTAssertEqual(agent.revision, before.revision + 1)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.clicks, project.clicks)
    }

    func test_timeProperty_outsideExistingWindowsRejectsNativeAndMCPAtomically() async throws {
        let (store, project) = try fixture()
        let library = store.repository.rootURL.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: library)
        for time in [-0.1, 0.5, project.clicks[0].indicator.endTime, 5, 10] {
            var edited = project
            edited.clicks[0].time = time
            edited.clicks[0].description.text = "Must not publish"
            store.errorMessage = nil
            ProjectWorkspaceView(store: store, projectID: project.id).projectBinding(for: project).wrappedValue = edited
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertEqual(try Data(contentsOf: library), bytes)
            let response = try await update(store, project: project, fields: [
                "time": time, "description": "Must not publish"
            ])
            XCTAssertTrue(response.isError, "time=\(time): \(response.text)")
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertEqual(try Data(contentsOf: library), bytes)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
        }
    }

    func test_timeAndExplicitWindows_canMoveTogetherWithoutChangingOtherFields() async throws {
        let (store, project) = try fixture()
        let response = try await update(store, project: project, fields: [
            "time": 5.0, "indicator_start_time": 4.8, "indicator_end_time": 5.5,
            "description_start_time": 4.8, "description_end_time": 6.0,
            "subtitle_start_time": 4.8, "subtitle_end_time": 6.0
        ])
        XCTAssertFalse(response.isError, response.text)
        let cue = try XCTUnwrap(store.project(id: project.id)?.clicks.first)
        XCTAssertEqual(cue.time, 5)
        XCTAssertEqual(cue.sourceTime, 5)
        XCTAssertEqual(cue.description.text, project.clicks[0].description.text)
        XCTAssertEqual(cue.cueSubtitle.style, project.clicks[0].cueSubtitle.style)
        XCTAssertEqual(cue.indicator.startTime, 4.8)
        XCTAssertEqual(cue.indicator.endTime, 5.5)
    }

    func test_groupDrag_stillMovesEveryWindowWhileTimePropertyDoesNot() throws {
        let (_, project) = try fixture()
        let old = project.clicks[0]
        let moved = try TimelineLayerEditor.move(.click(old.id), by: 4, in: project).clicks[0]
        XCTAssertEqual(moved.time, old.time + 4)
        XCTAssertEqual(moved.indicator.startTime, old.indicator.startTime + 4)
        XCTAssertEqual(moved.description.endTime, old.description.endTime + 4)
        XCTAssertEqual(moved.cueSubtitle.endTime, old.cueSubtitle.endTime + 4)
    }

    /// Creates a temporary model fixture; property editing does not decode video.
    private func fixture() throws -> (AppStore, DemoProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let id = UUID()
        let asset = try repository.prepareVideoRecordingURL(projectID: id)
        try Data("synthetic property fixture".utf8).write(to: asset.url)
        var project = DemoProject(id: id, name: "Click property",
            recording: VideoRecordingAsset(filename: asset.filename, duration: 10, width: 1280, height: 720))
        project = try VideoTimelineEditor.addClickCue(to: project, at: 1, x: 0.5, y: 0.5)
        project.clicks[0].description.text = "Description"
        project.clicks[0].cueSubtitle.text = "Subtitle"
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: id)))
    }

    /// Exercises the production host instead of duplicating its editing logic in tests.
    private func update(
        _ store: AppStore, project: DemoProject, fields: [String: Any]
    ) async throws -> StorybirdControlResponse {
        var arguments: [String: Any] = [
            "project_id": project.id.uuidString, "click_id": project.clicks[0].id.uuidString,
            "expected_revision": project.revision
        ]
        arguments.merge(fields) { _, new in new }
        return await StorybirdExternalControlHost(store: store).handle(StorybirdControlRequest(
            name: "storybird_update_click",
            argumentsJSON: try JSONSerialization.data(withJSONObject: arguments)
        ))
    }
}
