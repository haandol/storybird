import Foundation
import XCTest
@testable import StorybirdCore

final class ProjectStorageLocationTests: XCTestCase {
    func test_live_usesDocumentsAndPreservesExistingApplicationSupportLibrary() throws {
        let manager = try fixture()
        let oldRoot = manager.support.appendingPathComponent("Storybird", isDirectory: true)
        let old = ProjectRepository(rootURL: oldRoot)
        let project = DemoProject(name: "Previous library", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        try old.saveProjects([project])
        let index = oldRoot.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: index)

        let live = try ProjectRepository.live(fileManager: manager)
        XCTAssertEqual(live.rootURL, manager.documents.appendingPathComponent("Storybird", isDirectory: true))
        XCTAssertEqual(live.sharedRootURL, oldRoot)
        XCTAssertEqual(try live.loadProjects(), [])
        try live.saveProjects([DemoProject(name: "Documents project")])
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertEqual(try old.loadProjects(), [project])
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.rootURL.appendingPathComponent("Voices").path))
    }

    func test_live_keepsOpenLaneCopyInApplicationSupport() throws {
        let manager = try fixture()
        let legacyRoot = manager.support.appendingPathComponent("OpenLane", isDirectory: true)
        let legacy = ProjectRepository(rootURL: legacyRoot)
        let project = DemoProject(name: "Legacy", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        try legacy.saveProjects([project])

        let live = try ProjectRepository.live(fileManager: manager)
        XCTAssertEqual(try live.loadProjects(), [])
        XCTAssertEqual(try ProjectRepository(rootURL: live.sharedRootURL).loadProjects(), [project])
        XCTAssertEqual(try legacy.loadProjects(), [project])
    }

    func test_documentsUnavailable_throwsWithoutUsingApplicationSupportForProjects() throws {
        let manager = try fixture()
        manager.documentsUnavailable = true
        XCTAssertThrowsError(try ProjectRepository.live(fileManager: manager))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.documents.path))
    }

    private func fixture() throws -> StorageLocationFileManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return StorageLocationFileManager(root: root)
    }
}

private final class StorageLocationFileManager: FileManager, @unchecked Sendable {
    let documents: URL
    let support: URL
    var documentsUnavailable = false

    init(root: URL) {
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        support = root.appendingPathComponent("Application Support", isDirectory: true)
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [support] : [documents]
    }

    override func url(
        for directory: SearchPathDirectory,
        in domain: SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        if documentsUnavailable { throw CocoaError(.fileReadNoPermission) }
        return directory == .documentDirectory ? documents : support
    }
}
