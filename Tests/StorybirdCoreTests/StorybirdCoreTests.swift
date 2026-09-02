import CoreGraphics
import Foundation
@testable import StorybirdCore
import XCTest

final class StorybirdCoreTests: XCTestCase {
    func test_hotspotCoordinates_clampToUnitRange() {
        let hotspot = Hotspot(x: -0.25, y: 1.8)

        XCTAssertEqual(hotspot.x, 0)
        XCTAssertEqual(hotspot.y, 1)
    }

    func test_analyticsSummary_countsOnlyStartedCompletedSessions() {
        let firstSession = UUID()
        let secondSession = UUID()
        let orphanCompletion = UUID()
        let step = DemoStep(title: "Start", assetFilename: "start.png")
        let project = DemoProject(
            name: "Analytics",
            steps: [step],
            events: [
                AnalyticsEvent(sessionID: firstSession, type: .sessionStarted),
                AnalyticsEvent(
                    sessionID: firstSession,
                    type: .stepViewed,
                    stepID: step.id
                ),
                AnalyticsEvent(
                    sessionID: firstSession,
                    type: .hotspotClicked,
                    stepID: step.id
                ),
                AnalyticsEvent(sessionID: firstSession, type: .completed),
                AnalyticsEvent(sessionID: secondSession, type: .sessionStarted),
                AnalyticsEvent(sessionID: orphanCompletion, type: .completed),
            ]
        )

        let summary = AnalyticsSummary(project: project)

        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.completedSessions, 1)
        XCTAssertEqual(summary.hotspotClicks, 1)
        XCTAssertEqual(summary.completionRate, 0.5)
        XCTAssertEqual(summary.stepResults.first?.views, 1)
    }

    func test_aspectFit_centersWideContent() {
        let frame = AspectFit.frame(
            contentSize: CGSize(width: 1600, height: 900),
            in: CGRect(x: 0, y: 0, width: 800, height: 800)
        )

        XCTAssertEqual(frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.height, 450, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 175, accuracy: 0.001)
    }

    func test_appKitCoordinates_flipMacScreenYAxis() {
        let point = RecordingGeometry.normalizedClick(
            screenPoint: CGPoint(x: 300, y: 650),
            screenFrame: CGRect(x: 100, y: 200, width: 800, height: 600)
        )

        XCTAssertEqual(point?.x ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 0.001)
    }

    func test_appKitCoordinates_rejectPointOutsideDisplay() {
        let point = RecordingGeometry.normalizedClick(
            screenPoint: CGPoint(x: -50, y: 300),
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNil(point)
    }

    func test_captureCoordinates_useTopLeftOrigin() {
        let point = RecordingGeometry.normalizedCaptureClick(
            capturePoint: CGPoint(x: 500, y: 250),
            captureFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        XCTAssertEqual(point?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 0.001)
    }

    func test_recordedClick_linksPreviousScreenToNewScreen() throws {
        let first = DemoStep(title: "Before", assetFilename: "before.png")
        let second = DemoStep(title: "After", assetFilename: "after.png")
        var project = DemoProject(name: "Recorded", steps: [first])

        let newStepID = try RecordedFlowBuilder.append(
            nextStep: second,
            clickPoint: CGPoint(x: 0.72, y: 0.31),
            from: first.id,
            to: &project
        )

        XCTAssertEqual(project.steps.count, 2)
        XCTAssertEqual(newStepID, second.id)
        XCTAssertEqual(project.steps[0].hotspots.count, 1)
        XCTAssertEqual(project.steps[0].hotspots[0].targetStepID, second.id)
        XCTAssertEqual(project.steps[0].hotspots[0].x, 0.72, accuracy: 0.001)
        XCTAssertEqual(project.steps[0].hotspots[0].y, 0.31, accuracy: 0.001)
    }

    func test_repository_roundTripsProjectLibrary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(
            name: "Round trip",
            summary: "Stored locally",
            steps: [
                DemoStep(title: "Start", assetFilename: "start.png"),
            ]
        )

        try repository.saveProjects([project])
        let loaded = try repository.loadProjects()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, project.id)
        XCTAssertEqual(loaded.first?.name, project.name)
        XCTAssertEqual(loaded.first?.summary, project.summary)
        XCTAssertEqual(loaded.first?.steps, project.steps)
        XCTAssertEqual(loaded.first?.theme, project.theme)
    }

    func test_legacyMigration_copiesLibraryAndKeepsOriginal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(
            "OpenLane",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(
            "Storybird",
            isDirectory: true
        )
        let legacyAsset = legacy.appendingPathComponent("Assets/example.png")
        try FileManager.default.createDirectory(
            at: legacyAsset.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacyAsset)

        try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy,
            to: destination
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyAsset.path)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: destination.appendingPathComponent(
                    "Assets/example.png"
                )
            ),
            Data("legacy".utf8)
        )
    }

    func test_legacyMigration_existingStorybirdLibraryWins() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent(
            "OpenLane",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(
            "Storybird",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let existing = destination.appendingPathComponent("library.json")
        try Data("storybird".utf8).write(to: existing)

        try ProjectRepository.migrateLegacyLibraryIfNeeded(
            from: legacy,
            to: destination
        )

        XCTAssertEqual(
            try Data(contentsOf: existing),
            Data("storybird".utf8)
        )
    }

    func test_staticExport_copiesAssetsAndEscapesScriptBoundary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: source.appendingPathComponent("capture.png")
        )
        let project = DemoProject(
            name: "Launch </script> Demo",
            steps: [
                DemoStep(title: "Start", assetFilename: "capture.png"),
            ]
        )

        let destination = try StaticDemoExporter().export(
            project: project,
            sourceAssetsDirectory: source,
            into: output
        )
        let html = try String(
            contentsOf: destination.appendingPathComponent("index.html"),
            encoding: .utf8
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("assets/step-1.png")
                    .path
            )
        )
        XCTAssertTrue(html.contains("Launch &lt;/script&gt; Demo"))
        XCTAssertTrue(html.contains("<\\/script>"))
        XCTAssertFalse(html.contains("\"name\" : \"Launch </script> Demo\""))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
