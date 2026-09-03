import AppKit
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

    func test_failedAgentImport_followedByIdenticalBindingWritePreservesLibrary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Existing project")
        try repository.saveProjects([project])
        let libraryURL = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: libraryURL)
        let package = try makeUnsupportedPackage(in: root)
        let store = AppStore(repository: repository)
        let loadedProject = try XCTUnwrap(store.project(id: project.id))

        store.importAgentRecording(at: package)
        store.replaceProject(loadedProject)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.projects.map(\.id), [project.id])
        XCTAssertEqual(
            store.project(id: project.id)?.updatedAt,
            loadedProject.updatedAt
        )
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
    }

    func test_moveStep_preservesHotspotTargetID() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let first = DemoStep(title: "First", assetFilename: "first.png")
        let second = DemoStep(title: "Second", assetFilename: "second.png")
        let third = DemoStep(title: "Third", assetFilename: "third.png")
        var project = DemoProject(
            name: "Reorder",
            steps: [first, second, third]
        )
        project.steps[0].hotspots = [
            Hotspot(x: 0.5, y: 0.5, targetStepID: third.id),
        ]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)

        store.moveStep(projectID: project.id, stepID: third.id, offset: -1)

        let updated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(updated.steps.map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(
            updated.steps[0].hotspots[0].targetStepID,
            third.id
        )
    }

    func test_deleteStep_clearsHotspotsTargetingDeletedScreen() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let first = DemoStep(title: "First", assetFilename: "first.png")
        let second = DemoStep(title: "Second", assetFilename: "second.png")
        var project = DemoProject(name: "Delete", steps: [first, second])
        project.steps[0].hotspots = [
            Hotspot(x: 0.5, y: 0.5, targetStepID: second.id),
        ]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)

        store.deleteStep(projectID: project.id, stepID: second.id)

        let updated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(updated.steps.map(\.id), [first.id])
        XCTAssertNil(updated.steps[0].hotspots[0].targetStepID)
    }

    func test_appendRecordedClick_usesClickTimeImageForHotspotStep() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Recorded")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let sourceStepID = try store.beginRecordedFlow(
            with: image(color: .red),
            in: project.id
        )
        let initialStep = try XCTUnwrap(
            store.project(id: project.id)?.steps.first
        )
        let initialAssetURL = repository.assetURL(
            projectID: project.id,
            filename: initialStep.assetFilename
        )

        let nextStepID = try store.appendRecordedClick(
            at: CGPoint(x: 0.72, y: 0.31),
            clickedImage: image(color: .green),
            resultingImage: image(color: .blue),
            from: sourceStepID,
            in: project.id
        )

        let updated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(updated.steps.count, 2)
        XCTAssertEqual(updated.steps[1].id, nextStepID)
        XCTAssertEqual(updated.steps[0].hotspots[0].targetStepID, nextStepID)
        XCTAssertEqual(updated.steps[0].hotspots[0].x, 0.72, accuracy: 0.001)
        XCTAssertEqual(updated.steps[0].hotspots[0].y, 0.31, accuracy: 0.001)
        try assertImage(
            at: repository.assetURL(
                projectID: project.id,
                filename: updated.steps[0].assetFilename
            ),
            matches: .green
        )
        try assertImage(
            at: repository.assetURL(
                projectID: project.id,
                filename: updated.steps[1].assetFilename
            ),
            matches: .blue
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: initialAssetURL.path)
        )
    }

    private func makeUnsupportedPackage(in root: URL) throws -> URL {
        let package = root.appendingPathComponent(
            "invalid.storybirdrecording",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest: [String: Any] = [
            "version": 999,
            "projectName": "Invalid project",
            "sourceName": "Synthetic source",
            "steps": [
                ["assetFilename": "step-1.png"],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return package
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func image(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
    }

    private func assertImage(
        at url: URL,
        matches expectedColor: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = try XCTUnwrap(
            NSImage(contentsOf: url),
            file: file,
            line: line
        )
        let representation = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init),
            file: file,
            line: line
        )
        let actual = try XCTUnwrap(
            representation.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB),
            file: file,
            line: line
        )
        let expected = try XCTUnwrap(
            expectedColor.usingColorSpace(.sRGB),
            file: file,
            line: line
        )

        let actualComponents = [
            actual.redComponent,
            actual.greenComponent,
            actual.blueComponent,
        ]
        let expectedComponents = [
            expected.redComponent,
            expected.greenComponent,
            expected.blueComponent,
        ]
        XCTAssertEqual(
            dominantComponent(in: actualComponents),
            dominantComponent(in: expectedComponents),
            file: file,
            line: line
        )
    }

    private func dominantComponent(in values: [CGFloat]) -> Int? {
        values.indices.max { values[$0] < values[$1] }
    }
}
