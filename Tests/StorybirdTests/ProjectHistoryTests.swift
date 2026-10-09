import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class ProjectHistoryTests: XCTestCase {
    func test_undo_saveFailure_preservesProjectAndHistoryUntilRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, repository, saved) = try editedProject(at: root)
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))

        try withBlockedLibraryWrite(at: root) {
            XCTAssertThrowsError(try store.undo(projectID: saved.id, expectedRevision: saved.revision))
            XCTAssertEqual(store.project(id: saved.id), saved)
            XCTAssertThrowsError(try store.redo(projectID: saved.id)) {
                XCTAssertEqual($0 as? RecordingStoreError, .noRedo)
            }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), library)

        let undone = try store.undo(projectID: saved.id, expectedRevision: saved.revision)
        XCTAssertEqual(undone.name, "Before")
        XCTAssertEqual(undone.revision, saved.revision + 1)
        XCTAssertThrowsError(try store.undo(projectID: saved.id)) {
            XCTAssertEqual($0 as? RecordingStoreError, .noUndo)
        }
        let redone = try store.redo(projectID: saved.id, expectedRevision: undone.revision)
        XCTAssertEqual(redone.name, "After")
        XCTAssertEqual(try repository.loadProjects().first?.name, redone.name)
    }

    func test_redo_saveFailure_preservesProjectAndHistoryUntilRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, repository, saved) = try editedProject(at: root)
        let undone = try store.undo(projectID: saved.id)
        let library = try Data(contentsOf: root.appendingPathComponent("library.json"))

        try withBlockedLibraryWrite(at: root) {
            XCTAssertThrowsError(try store.redo(projectID: saved.id, expectedRevision: undone.revision))
            XCTAssertEqual(store.project(id: saved.id), undone)
            XCTAssertThrowsError(try store.undo(projectID: saved.id)) {
                XCTAssertEqual($0 as? RecordingStoreError, .noUndo)
            }
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), library)

        let redone = try store.redo(projectID: saved.id, expectedRevision: undone.revision)
        XCTAssertEqual(redone.name, "After")
        XCTAssertEqual(redone.revision, undone.revision + 1)
        XCTAssertThrowsError(try store.redo(projectID: saved.id)) {
            XCTAssertEqual($0 as? RecordingStoreError, .noRedo)
        }
        let restored = try store.undo(projectID: saved.id, expectedRevision: redone.revision)
        XCTAssertEqual(restored.name, "Before")
        XCTAssertEqual(try repository.loadProjects().first?.name, restored.name)
    }

    func test_redo_staleExpectedRevision_preservesRedoHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, saved) = try editedProject(at: root)
        let undone = try store.undo(projectID: saved.id)

        XCTAssertThrowsError(try store.redo(projectID: saved.id, expectedRevision: saved.revision)) {
            XCTAssertEqual($0 as? RecordingStoreError, .revisionConflict(undone.revision))
        }
        XCTAssertEqual(store.project(id: saved.id), undone)
        let redone = try store.redo(projectID: saved.id, expectedRevision: undone.revision)
        XCTAssertEqual(redone.name, "After")
    }

    private func editedProject(at root: URL) throws -> (AppStore, ProjectRepository, DemoProject) {
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Before")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        var edited = project
        edited.name = "After"
        let saved = try store.saveProject(edited, expectedRevision: project.revision)
        return (store, repository, saved)
    }

    /// A directory at the library path forces a real atomic-write failure in the temporary repository.
    private func withBlockedLibraryWrite(at root: URL, check: () throws -> Void) throws {
        let fileManager = FileManager.default
        let library = root.appendingPathComponent("library.json")
        let backup = root.appendingPathComponent("library-backup.json")
        try fileManager.moveItem(at: library, to: backup)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: library)
            try? fileManager.moveItem(at: backup, to: library)
        }
        try check()
    }
}
