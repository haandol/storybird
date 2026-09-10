import Foundation
import XCTest
@testable import StorybirdCore

final class LibraryPublicationMigrationRegressionTests: XCTestCase {
    /// A failed copy must leave no authoritative destination that suppresses retry.
    func test_partialLegacyCopy_preservesSourceAndAllowsCompleteRetry() throws {
        let (root, legacy, destination) = try fixture()
        let manager = LibraryPublicationFileManager(failure: .copy)

        XCTAssertThrowsError(try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy, to: destination, fileManager: manager
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("library.json")), Data("complete".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["OpenLane"])

        try ProjectRepository.migrateLegacyLibraryIfNeeded(from: legacy, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("library.json")), Data("complete".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("library.json")), Data("complete".utf8))
    }

    /// Failure to publish a completed staging copy must preserve the source and permit retry.
    func test_legacyPublicationFailure_removesStagingAndKeepsSource() throws {
        let (root, legacy, destination) = try fixture()
        let manager = LibraryPublicationFileManager(failure: .publication)

        XCTAssertThrowsError(try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy, to: destination, fileManager: manager
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["OpenLane"])
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("library.json")), Data("complete".utf8))
    }

    /// An existing Storybird library is never replaced by a legacy copy.
    func test_existingDestination_keepsBothLibrariesUnchanged() throws {
        let (_, legacy, destination) = try fixture()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let index = destination.appendingPathComponent("library.json")
        try Data("current".utf8).write(to: index)

        XCTAssertNoThrow(try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy, to: destination,
            fileManager: LibraryPublicationFileManager(failure: .copy)
        ))
        XCTAssertEqual(try Data(contentsOf: index), Data("current".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("library.json")), Data("complete".utf8))
    }

    /// Builds isolated legacy bytes without accessing the user's actual libraries.
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-publication-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("OpenLane", isDirectory: true)
        let destination = root.appendingPathComponent("Storybird", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("complete".utf8).write(to: legacy.appendingPathComponent("library.json"))
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, legacy, destination)
    }
}

private final class LibraryPublicationFileManager: FileManager, @unchecked Sendable {
    enum Failure {
        case copy
        case publication
    }

    let failure: Failure

    /// Selects the precise filesystem boundary that fails during migration.
    init(failure: Failure) {
        self.failure = failure
        super.init()
    }

    /// Leaves partial bytes before failing, matching an interrupted directory copy.
    override func copyItem(at source: URL, to destination: URL) throws {
        if failure == .copy {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: destination.appendingPathComponent("partial"))
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: source, to: destination)
    }

    /// Rejects publication after a successful staging copy.
    override func moveItem(at source: URL, to destination: URL) throws {
        if failure == .publication { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
    }
}
