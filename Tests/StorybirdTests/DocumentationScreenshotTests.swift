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
        for name in [
            "welcome.png", "voice-narration.png", "voice-profile-creation.png",
            "storage-settings.png", "narration-drafts.png", "editor-app.png",
            "voice-settings-app.png", "voice-profile-dialog-app.png",
        ] {
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
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Demo narrator", referenceFilename: "reference.wav",
            referenceText: "Synthetic reference.", language: "english", consentConfirmed: true
        )
        try repository.saveVoiceProfiles([profile])
        let store = AppStore(
            repository: repository,
            voiceService: DocumentationVoiceService()
        )
        await store.refreshVoiceRuntimeState()

        try await render(
            VoiceProfileCreationView(store: store),
            size: CGSize(width: 620, height: 650),
            to: imageDirectory.appendingPathComponent("voice-profile-creation.png")
        )
        try await render(
            WelcomeView(
                store: store,
                onRecord: {},
                onImport: {}
            ),
            size: CGSize(width: 900, height: 600),
            to: imageDirectory.appendingPathComponent("welcome.png")
        )
        try await render(
            VoiceStudioView(
                store: store,
                refreshRuntimeOnAppear: false,
                inputDevices: [VoiceInputDevice(uid: "documentation-input", name: "Built-in Microphone")]
            ),
            size: CGSize(width: 680, height: 720),
            to: imageDirectory.appendingPathComponent(
                "voice-narration.png"
            )
        )
        let emptyVoiceStore = AppStore(
            repository: ProjectRepository(rootURL: root.appendingPathComponent("empty-voices")),
            voiceService: DocumentationVoiceService()
        )
        await emptyVoiceStore.refreshVoiceRuntimeState()
        try await render(
            VoiceStudioView(
                store: emptyVoiceStore,
                refreshRuntimeOnAppear: false,
                inputDevices: [VoiceInputDevice(uid: "documentation-input", name: "Built-in Microphone")]
            ),
            size: CGSize(width: 680, height: 720),
            to: imageDirectory.appendingPathComponent("voice-settings-app.png"),
            hostedInWindow: true
        )
        let domain = "storybird.docs.storage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try await render(
            StorybirdSettingsView(
                store: store,
                shortcutSettings: StorybirdShortcutSettings(defaults: defaults)
            ).generalTab,
            size: CGSize(width: 680, height: 720),
            to: imageDirectory.appendingPathComponent("storage-settings.png")
        )
        let project = DemoProject(
            name: "Service tutorial",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 20, width: 1280, height: 720),
            narrationDrafts: [NarrationDraft(
                voiceProfileID: profile.id, text: "Create your first project and see the result.",
                language: "english", filename: "synthetic.wav", state: .ready, duration: 3.2
            )]
        )
        try store.repository.saveProjects([project])
        _ = try repository.prepareVideoRecordingURL(projectID: project.id)
        try TestVideoFactory.makeToneWAV(
            at: repository.assetURL(projectID: project.id, filename: "synthetic.wav"), duration: 3.2
        )
        let narrationStore = AppStore(repository: store.repository, voiceService: DocumentationVoiceService())
        await narrationStore.refreshVoiceRuntimeState()
        try await render(
            TimelineAudioPanel(store: narrationStore, model: TimelineAudioModel(), projectID: project.id, playhead: 2),
            size: CGSize(width: 680, height: 680),
            to: imageDirectory.appendingPathComponent("narration-drafts.png")
        )
        let audioID = UUID()
        let video = try repository.prepareVideoRecordingURL(projectID: audioID)
        let media = try await TestVideoFactory.makeMovie(at: video.url, includeAudio: false, duration: 5)
        var layers: [NarrationClip] = []
        for (index, title) in ["Introduction · TTS", "Feature explanation · TTS", "Supporting audio"].enumerated() {
            let filename = "synthetic-audio-\(index).wav"
            try TestVideoFactory.makeToneWAV(at: repository.assetURL(projectID: audioID, filename: filename),
                duration: 2, frequency: Double(330 + index * 220))
            layers.append(NarrationClip(
                voiceProfileID: profile.id, filename: filename, text: title, language: "english",
                startTime: 0.2 + Double(index), duration: 2, volume: 0.5,
                name: title, fadeIn: 0.2, fadeOut: 0.2
            ))
        }
        let audioProject = DemoProject(id: audioID, name: "Prompt → TTS → Layered video",
            recording: VideoRecordingAsset(filename: video.filename, duration: media.duration, width: media.width, height: media.height),
            subtitles: [TimedSubtitle(startTime: 0.2, endTime: 2.2, text: "Create a video from your script.")],
            narrations: layers)
        try repository.saveProjects([audioProject])
        let audioStore = AppStore(repository: repository, voiceService: DocumentationVoiceService())
        try await render(ProjectWorkspaceView(store: audioStore, projectID: audioID),
            size: CGSize(width: 1100, height: 760),
            to: imageDirectory.appendingPathComponent("audio-layers.png"), hostedInWindow: true,
            openAudioForProject: audioID)
        try await render(ProjectAudioRecordingView(store: audioStore, projectID: audioID),
            size: CGSize(width: 620, height: 520),
            to: imageDirectory.appendingPathComponent("project-voice-recording.png"), hostedInWindow: true)
    }

    /// Renders real SwiftUI views with synthetic local state so documentation
    /// evidence never contains customer captures, recordings, or project data.
    private func render<Content: View>(
        _ content: Content,
        size: CGSize,
        to destination: URL,
        hostedInWindow: Bool = false,
        openAudioForProject: UUID? = nil
    ) async throws {
        let rootView = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .tint(.indigo)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window: NSWindow? = hostedInWindow ? NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        ) : nil
        window?.contentView = hostingView
        window?.orderFront(nil)
        defer { window?.orderOut(nil); window?.contentView = nil }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        if let openAudioForProject {
            NotificationCenter.default.post(name: .storybirdOpenProjectAudio, object: openAudioForProject)
            try await Task.sleep(for: .milliseconds(200))
        }
        hostingView.layoutSubtreeIfNeeded()

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
