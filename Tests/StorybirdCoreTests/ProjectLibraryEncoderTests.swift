import Foundation
import StorybirdCore
import XCTest

final class ProjectLibraryEncoderTests: XCTestCase {
    func test_cachedLibrary_sameRevisionEditsReorderAndDeletionRoundTrip() throws {
        let repository = try fixture()
        var first = project("First")
        let second = project("Second")
        try repository.saveProjects([first, second])
        first.name = "수정 \"quoted\"\nname"
        first.subtitles[0].text = "Changed without advancing revision"
        try repository.saveProjects([second, first])
        XCTAssertEqual(try repository.loadProjects(), [second, first])
        try repository.saveProjects([first])
        XCTAssertEqual(try repository.loadProjects(), [first])
        try repository.saveProjects([])
        XCTAssertEqual(try repository.loadProjects(), [])
        try repository.saveProjects([second])
        XCTAssertEqual(try repository.loadProjects(), [second])
    }

    func test_cachedLibrary_encodingFailurePreservesLastFileAndAllowsRetry() throws {
        let repository = try fixture()
        let original = project("Original")
        try repository.saveProjects([original])
        let url = repository.rootURL.appendingPathComponent("library.json")
        let before = try Data(contentsOf: url)
        var invalid = original
        invalid.sourceAudioVolume = .nan
        XCTAssertThrowsError(try repository.saveProjects([project("New"), invalid]))
        XCTAssertEqual(try Data(contentsOf: url), before)
        var corrected = original
        corrected.name = "Corrected"
        try repository.saveProjects([corrected])
        XCTAssertEqual(try repository.loadProjects(), [corrected])
    }

    func test_cachedLibrary_identicalInputStillWritesAndReportsFilesystemFailure() throws {
        let repository = try fixture()
        let value = project("Retried")
        try repository.saveProjects([value])
        let url = repository.rootURL.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try repository.saveProjects([value]))
        try FileManager.default.removeItem(at: url)
        try repository.saveProjects([value])
        XCTAssertEqual(try repository.loadProjects(), [value])
    }

    private func fixture() throws -> ProjectRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        return repository
    }

    private func project(_ name: String) -> DemoProject {
        DemoProject(name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: VideoRecordingAsset(filename: "source.mp4", duration: 10, width: 64, height: 48),
            subtitles: [TimedSubtitle(startTime: 1, endTime: 2, text: "Original")])
    }
}
