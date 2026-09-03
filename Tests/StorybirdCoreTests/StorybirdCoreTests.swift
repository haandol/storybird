import AppKit
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

    func test_textOverlayOpacity_clampsToSupportedRange() {
        var style = TextOverlayStyle(backgroundOpacity: -0.25)

        XCTAssertEqual(style.backgroundOpacity, 0)

        style.backgroundOpacity = 1.8

        XCTAssertEqual(style.backgroundOpacity, 1)
    }

    func test_legacyOverlayFields_decodeWithCompatibleDefaults() throws {
        let stepID = UUID()
        let hotspotID = UUID()
        let json = """
        {
          "id": "\(stepID.uuidString)",
          "title": "Legacy screen",
          "caption": "Existing caption",
          "assetFilename": "legacy.png",
          "hotspots": [
            {
              "id": "\(hotspotID.uuidString)",
              "x": 0.75,
              "y": 0.2,
              "kind": "click",
              "title": "Continue",
              "body": "",
              "targetStepID": null
            }
          ]
        }
        """

        let step = try JSONDecoder().decode(
            DemoStep.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(step.caption, "Existing caption")
        XCTAssertEqual(step.subtitlePosition, .bottom)
        XCTAssertEqual(step.subtitleStyle, .default)
        XCTAssertEqual(step.hotspots.first?.caption, "")
        XCTAssertEqual(step.hotspots.first?.captionStyle, .default)
    }

    func test_legacyOverlayDecode_missingExistingCaptionFails() {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Missing caption",
          "assetFilename": "legacy.png",
          "hotspots": []
        }
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DemoStep.self,
                from: Data(json.utf8)
            )
        )
    }

    func test_legacyHotspotDecode_preservesStoredCoordinates() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "x": -0.25,
          "y": 1.8,
          "kind": "click",
          "title": "Continue",
          "body": "",
          "targetStepID": null
        }
        """

        let hotspot = try JSONDecoder().decode(
            Hotspot.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(hotspot.x, -0.25)
        XCTAssertEqual(hotspot.y, 1.8)
        XCTAssertEqual(hotspot.caption, "")
        XCTAssertEqual(hotspot.captionStyle, .default)
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

    func test_captureCoordinates_rejectPointOutsideCaptureFrame() {
        let point = RecordingGeometry.normalizedCaptureClick(
            capturePoint: CGPoint(x: 99, y: 250),
            captureFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        XCTAssertNil(point)
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

    func test_staticExport_usesUniqueDestinationAndCopiesOnlyReferencedAssets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let occupied = output.appendingPathComponent(
            "unique-demo",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: occupied,
            withIntermediateDirectories: true
        )
        let marker = occupied.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: source.appendingPathComponent("capture.png")
        )
        try Data("unused".utf8).write(
            to: source.appendingPathComponent("unused.png")
        )
        let project = DemoProject(
            name: "Unique demo",
            steps: [
                DemoStep(title: "Start", assetFilename: "capture.png"),
            ]
        )

        let destination = try StaticDemoExporter().export(
            project: project,
            sourceAssetsDirectory: source,
            into: output
        )

        XCTAssertEqual(destination.lastPathComponent, "unique-demo-2")
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("assets/step-1.png")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent("assets/unused.png")
                    .path
            )
        )
    }

    func test_staticExport_preservesTextOverlayContract() throws {
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
            name: "Overlay demo",
            steps: [
                DemoStep(
                    title: "Start",
                    caption: "Top subtitle",
                    subtitlePosition: .top,
                    subtitleStyle: TextOverlayStyle(
                        backgroundHex: "#123456",
                        backgroundOpacity: 0.25
                    ),
                    assetFilename: "capture.png",
                    hotspots: [
                        Hotspot(
                            x: 0.8,
                            y: 0.15,
                            caption: "Click here",
                            captionStyle: TextOverlayStyle(
                                backgroundHex: "#654321",
                                backgroundOpacity: 0
                            )
                        ),
                    ]
                ),
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
        let manifestData = try Data(
            contentsOf: destination.appendingPathComponent("demo.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(DemoProject.self, from: manifestData)

        XCTAssertTrue(html.contains("subtitle.textContent = step.caption"))
        XCTAssertTrue(html.contains("caption.textContent = hotspot.caption"))
        XCTAssertTrue(html.contains("step.subtitlePosition === \"top\""))
        XCTAssertEqual(exported.steps.first?.subtitlePosition, .top)
        XCTAssertEqual(exported.steps.first?.subtitleStyle.backgroundOpacity, 0.25)
        XCTAssertEqual(exported.steps.first?.hotspots.first?.caption, "Click here")
        XCTAssertEqual(
            exported.steps.first?.hotspots.first?.captionStyle.backgroundOpacity,
            0
        )
    }

    func test_agentRecordingImport_buildsOrderedProject() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(
            rootURL: root.appendingPathComponent("library", isDirectory: true)
        )
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Agent checkout",
                sourceName: "Amazon browser",
                steps: [
                    .init(assetFilename: "step-1.png"),
                    .init(
                        assetFilename: "step-2.png",
                        clickFromPrevious: .init(x: 0.72, y: 0.08)
                    ),
                ]
            )
        )

        let project = try AgentRecordingBundleImporter(
            repository: repository
        ).importBundle(at: package)

        XCTAssertEqual(project.name, "Agent checkout")
        XCTAssertEqual(project.summary, "Agent recording from Amazon browser")
        XCTAssertEqual(project.steps.map(\.title), [
            "Agent screen 1",
            "Agent screen 2",
        ])
        XCTAssertEqual(project.steps[0].hotspots.count, 1)
        XCTAssertEqual(project.steps[0].hotspots[0].x, 0.72, accuracy: 0.001)
        XCTAssertEqual(project.steps[0].hotspots[0].y, 0.08, accuracy: 0.001)
        XCTAssertEqual(
            project.steps[0].hotspots[0].targetStepID,
            project.steps[1].id
        )
        for step in project.steps {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repository.assetURL(
                        projectID: project.id,
                        filename: step.assetFilename
                    ).path
                )
            )
        }
    }

    func test_agentRecordingLibraryImport_savesNewProjectWithExistingProjects() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(
            rootURL: root.appendingPathComponent("library", isDirectory: true)
        )
        let existing = DemoProject(name: "Existing project")
        try repository.saveProjects([existing])
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Imported project",
                sourceName: "Browser",
                steps: [
                    .init(assetFilename: "step-1.png"),
                ]
            )
        )

        let result = try AgentRecordingLibraryImporter(
            repository: repository
        ).importBundle(at: package, into: [existing])
        let loaded = try repository.loadProjects()

        XCTAssertEqual(result.project.name, "Imported project")
        XCTAssertEqual(result.projects.map(\.name), [
            "Imported project",
            "Existing project",
        ])
        XCTAssertEqual(loaded.map(\.id), result.projects.map(\.id))
        XCTAssertEqual(loaded.map(\.name), result.projects.map(\.name))
        XCTAssertEqual(
            loaded.map { $0.steps.map(\.id) },
            result.projects.map { $0.steps.map(\.id) }
        )
    }

    func test_agentRecordingLibraryImport_saveFailureRollsBackAssetsAndLibrary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent(
            "library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: libraryRoot,
            withIntermediateDirectories: true
        )
        let libraryURL = libraryRoot.appendingPathComponent(
            "library.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: libraryURL,
            withIntermediateDirectories: true
        )
        let marker = libraryURL.appendingPathComponent("existing-marker")
        try Data("existing".utf8).write(to: marker)

        let repository = ProjectRepository(rootURL: libraryRoot)
        let existing = DemoProject(name: "Existing project")
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Rejected project",
                sourceName: "Browser",
                steps: [
                    .init(assetFilename: "step-1.png"),
                ]
            )
        )

        XCTAssertThrowsError(
            try AgentRecordingLibraryImporter(
                repository: repository
            ).importBundle(at: package, into: [existing])
        )
        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
        let assetsRoot = libraryRoot.appendingPathComponent(
            "Assets",
            isDirectory: true
        )
        let remainingAssets = try FileManager.default.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingAssets.isEmpty)
    }

    func test_agentRecordingImport_rejectsOutOfRangeClickBeforeWritingAssets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let repository = ProjectRepository(rootURL: library)
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Invalid coordinates",
                sourceName: "Browser",
                steps: [
                    .init(assetFilename: "step-1.png"),
                    .init(
                        assetFilename: "step-2.png",
                        clickFromPrevious: .init(x: 1.1, y: 0.5)
                    ),
                ]
            )
        )

        XCTAssertThrowsError(
            try AgentRecordingBundleImporter(
                repository: repository
            ).importBundle(at: package)
        ) { error in
            guard case AgentRecordingBundleError.invalidCoordinate(1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.appendingPathComponent("Assets").path
            )
        )
    }

    func test_agentRecordingImport_rejectsAssetPathTraversal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Unsafe package",
                sourceName: "Browser",
                steps: [
                    .init(assetFilename: "../secret.png"),
                ]
            ),
            createAssets: false
        )

        XCTAssertThrowsError(
            try AgentRecordingBundleImporter(
                repository: ProjectRepository(
                    rootURL: root.appendingPathComponent("library")
                )
            ).importBundle(at: package)
        ) { error in
            guard case AgentRecordingBundleError.invalidAssetName(
                "../secret.png"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_agentRecordingImport_rejectsSymbolicLinkAsset() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = AgentRecordingManifest(
            projectName: "Linked package",
            sourceName: "Browser",
            steps: [
                .init(assetFilename: "step-1.png"),
            ]
        )
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: manifest,
            createAssets: false
        )
        let external = root.appendingPathComponent("external.png")
        try writeTestPNG(to: external)
        let linkedAsset = package
            .appendingPathComponent("assets")
            .appendingPathComponent("step-1.png")
        try FileManager.default.createSymbolicLink(
            at: linkedAsset,
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try AgentRecordingBundleImporter(
                repository: ProjectRepository(
                    rootURL: root.appendingPathComponent("library")
                )
            ).importBundle(at: package)
        ) { error in
            guard case AgentRecordingBundleError.symbolicLink(
                "step-1.png"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_agentRecordingImport_rejectsNonPNGData() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = AgentRecordingManifest(
            projectName: "Invalid image",
            sourceName: "Browser",
            steps: [
                .init(assetFilename: "step-1.png"),
            ]
        )
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: manifest,
            createAssets: false
        )
        try Data("not a png".utf8).write(
            to: package
                .appendingPathComponent("assets")
                .appendingPathComponent("step-1.png")
        )

        XCTAssertThrowsError(
            try AgentRecordingBundleImporter(
                repository: ProjectRepository(
                    rootURL: root.appendingPathComponent("library")
                )
            ).importBundle(at: package)
        ) { error in
            guard case AgentRecordingBundleError.unreadableAsset(
                "step-1.png"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func test_agentRecordingImport_rejectsUnknownManifestFields() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makeAgentRecordingPackage(
            in: root,
            manifest: AgentRecordingManifest(
                projectName: "Extra data",
                sourceName: "Browser",
                steps: [
                    .init(assetFilename: "step-1.png"),
                ]
            )
        )
        let unsafeManifest: [String: Any] = [
            "version": 1,
            "projectName": "Extra data",
            "sourceName": "Browser",
            "steps": [
                ["assetFilename": "step-1.png"],
            ],
            "cookies": ["session": "secret"],
        ]
        try JSONSerialization.data(
            withJSONObject: unsafeManifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        XCTAssertThrowsError(
            try AgentRecordingBundleImporter(
                repository: ProjectRepository(
                    rootURL: root.appendingPathComponent("library")
                )
            ).importBundle(at: package)
        ) { error in
            guard case AgentRecordingBundleError.unexpectedManifestField(
                "manifest.cookies"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeAgentRecordingPackage(
        in root: URL,
        manifest: AgentRecordingManifest,
        createAssets: Bool = true
    ) throws -> URL {
        let package = root.appendingPathComponent(
            "recording.storybirdrecording",
            isDirectory: true
        )
        let assets = package.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        if createAssets {
            for filename in Set(manifest.steps.map(\.assetFilename))
            where !filename.contains("/") && !filename.contains("\\") {
                try writeTestPNG(
                    to: assets.appendingPathComponent(filename)
                )
            }
        }
        return package
    }

    private func writeTestPNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        let data = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try data.write(to: url, options: .atomic)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
