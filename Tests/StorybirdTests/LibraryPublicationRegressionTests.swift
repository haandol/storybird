import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class LibraryPublicationAssetRegressionTests: XCTestCase {
    /// The public replacement boundary must reject missing audio without adding an undo entry.
    func test_mcpReplacement_missingNarrationPreservesProjectRevisionAndUndo() async throws {
        let (store, project) = try await fixture()
        try await assertRejectedNarration(store: store, project: project)
    }

    /// A .wav extension alone does not make corrupt bytes a publishable narration.
    func test_mcpReplacement_corruptNarrationPreservesProjectRevisionAndUndo() async throws {
        let (store, project) = try await fixture()
        try Data("not audio".utf8).write(to: narrationURL(store, project))
        try await assertRejectedNarration(store: store, project: project)
    }

    /// A partial WAV must not publish the original claimed playback duration.
    func test_mcpReplacement_truncatedNarrationPreservesProjectRevisionAndUndo() async throws {
        let (store, project) = try await fixture()
        let url = narrationURL(store, project)
        try TestVideoFactory.makeToneWAV(at: url, duration: 1)
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count / 2).write(to: url)
        try await assertRejectedNarration(store: store, project: project)
    }

    /// Empty files must not cross the same asset-publication boundary.
    func test_mcpReplacement_emptyNarrationPreservesProjectRevisionAndUndo() async throws {
        let (store, project) = try await fixture()
        try Data().write(to: narrationURL(store, project))
        try await assertRejectedNarration(store: store, project: project)
    }

    /// A complete project-owned WAV can be published and restored from retained undo media.
    func test_completeNarration_publishesOnceAndSurvivesDeleteUndo() async throws {
        let (store, project) = try await fixture()
        let url = narrationURL(store, project)
        try TestVideoFactory.makeToneWAV(at: url, duration: 1)
        let bytes = try Data(contentsOf: url)
        var replacement = project
        replacement.narrations = [narration()]
        let response = try await replace(replacement, in: store)
        XCTAssertFalse(response.isError, response.text)
        let placed = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(placed.revision, project.revision + 1)
        var removed = placed
        removed.narrations = []
        _ = try store.saveProject(removed, expectedRevision: placed.revision)
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.narrations, placed.narrations)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// Compares durable bytes and undo behavior around a rejected full replacement.
    private func assertRejectedNarration(store: AppStore, project: DemoProject) async throws {
        let index = store.repository.rootURL.appendingPathComponent("library.json")
        let indexBytes = try Data(contentsOf: index)
        let source = store.repository.assetURL(
            projectID: project.id, filename: try XCTUnwrap(project.recording).filename
        )
        let sourceBytes = try Data(contentsOf: source)
        var replacement = project
        replacement.narrations = [narration()]
        let response = try await replace(replacement, in: store)

        XCTAssertTrue(response.isError, "Incomplete audio must not be committed.")
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertEqual(try Data(contentsOf: index), indexBytes)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        let undone = try store.undo(projectID: project.id)
        XCTAssertEqual(undone.name, "Original")
        XCTAssertTrue(undone.narrations.isEmpty)
    }

    /// Calls the same full-replacement handler used by the authenticated companion.
    private func replace(_ project: DemoProject, in store: AppStore) async throws -> StorybirdControlResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let host = StorybirdExternalControlHost(store: store)
        return await host.handle(StorybirdControlRequest(
            name: "storybird_replace_project",
            argumentsJSON: try JSONSerialization.data(withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": project.revision,
                "project_json": String(decoding: try encoder.encode(project), as: UTF8.self),
            ])
        ))
    }

    /// Uses a valid one-second narration shape so the failure is exclusively media validation.
    private func narration() -> NarrationClip {
        NarrationClip(
            voiceProfileID: UUID(), filename: "publication.wav",
            text: "Synthetic narration", startTime: 0, duration: 1
        )
    }

    /// Resolves the candidate within the owning project's temporary asset directory.
    private func narrationURL(_ store: AppStore, _ project: DemoProject) -> URL {
        store.repository.assetURL(projectID: project.id, filename: "publication.wav")
    }

    /// Creates real synthetic source media and one successful edit for undo assertions.
    private func fixture() async throws -> (AppStore, DemoProject) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-publication-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let prepared = try repository.prepareVideoRecordingURL(projectID: id)
        let video = try await TestVideoFactory.makeMovie(at: prepared.url, includeAudio: false, duration: 2)
        let original = DemoProject(
            id: id, name: "Original",
            recording: VideoRecordingAsset(
                filename: prepared.filename, duration: video.duration,
                width: video.width, height: video.height
            )
        )
        try repository.saveProjects([original])
        let store = AppStore(repository: repository)
        var edited = try XCTUnwrap(store.project(id: id))
        edited.name = "Edited"
        return (store, try store.saveProject(edited, expectedRevision: edited.revision))
    }
}
