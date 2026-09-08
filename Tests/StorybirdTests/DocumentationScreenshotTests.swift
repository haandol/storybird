import AppKit
import StorybirdCore
import SwiftUI
@testable import Storybird
import XCTest

@MainActor
final class DocumentationScreenshotTests: XCTestCase {
    func test_readmeScreenshotAssets_existAndAreRenderable() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        for name in ["welcome.png", "voice-narration.png"] {
            let relativePath = "docs/images/\(name)"
            XCTAssertTrue(
                readme.contains(relativePath),
                "README must reference \(relativePath)."
            )
            let data = try Data(
                contentsOf: repositoryRoot.appendingPathComponent(
                    relativePath
                )
            )
            let image = try XCTUnwrap(
                NSBitmapImageRep(data: data),
                "\(relativePath) must be a readable PNG."
            )
            XCTAssertGreaterThanOrEqual(image.pixelsWide, 600)
            XCTAssertGreaterThanOrEqual(image.pixelsHigh, 500)
        }
    }

    func test_generateSyntheticReadmeScreenshots() async throws {
        guard ProcessInfo.processInfo.environment[
            "STORYBIRD_UPDATE_DOC_SCREENSHOTS"
        ] == "1" else {
            throw XCTSkip(
                "Set STORYBIRD_UPDATE_DOC_SCREENSHOTS=1 to update docs/images."
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "storybird-docs-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(
            repository: ProjectRepository(rootURL: root),
            voiceService: DocumentationVoiceService()
        )
        await store.refreshVoiceRuntimeState()

        try render(
            WelcomeView(
                store: store,
                onRecord: {},
                onImport: {}
            ),
            size: CGSize(width: 900, height: 600),
            to: imageDirectory.appendingPathComponent("welcome.png")
        )
        try render(
            VoiceStudioView(
                store: store,
                refreshRuntimeOnAppear: false
            ),
            size: CGSize(width: 620, height: 720),
            to: imageDirectory.appendingPathComponent(
                "voice-narration.png"
            )
        )
    }

    /// Renders real SwiftUI views with synthetic local state so documentation
    /// evidence never contains customer captures, recordings, or project data.
    private func render<Content: View>(
        _ content: Content,
        size: CGSize,
        to destination: URL
    ) throws {
        let rootView = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .tint(.indigo)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: bitmap
        )
        let png = try XCTUnwrap(
            bitmap.representation(
                using: .png,
                properties: [:]
            )
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: destination, options: .atomic)
    }

    private var imageDirectory: URL {
        repositoryRoot
            .appendingPathComponent("docs/images", isDirectory: true)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor DocumentationVoiceService: VoiceSynthesisProviding {
    func prepared() async -> Bool { true }
    func prepare() async throws {}

    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        throw VoiceSynthesisError.invalidResponse
    }
}
