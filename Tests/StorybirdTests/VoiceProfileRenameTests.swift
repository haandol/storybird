import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class VoiceProfileRenameTests: XCTestCase {
    func test_rename_trimsNamePersistsAcrossRestartAndPreservesMediaAndProjects() throws {
        let (store, profile) = try fixture()
        let repository = store.repository
        let referenceURL = repository.voiceReferenceURL(
            profileID: profile.id, filename: profile.referenceFilename
        )
        let reference = try Data(contentsOf: referenceURL)
        let library = try Data(contentsOf: repository.rootURL.appendingPathComponent("library.json"))
        let projects = store.projects
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        model.name = " \n새 이름 \t"
        model.save()

        var expected = profile
        expected.name = "새 이름"
        XCTAssertTrue(model.isClosed)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(store.voiceProfiles, [expected])
        XCTAssertEqual(AppStore(repository: repository).voiceProfiles, [expected])
        XCTAssertEqual(store.projects, projects)
        XCTAssertEqual(try Data(contentsOf: repository.rootURL.appendingPathComponent("library.json")), library)
        XCTAssertEqual(try Data(contentsOf: referenceURL), reference)
    }

    func test_rename_duplicateDisplayNameKeepsDistinctProfiles() throws {
        let (store, profile) = try fixture()
        var second = profile
        second.id = UUID()
        second.name = "Other"
        try store.repository.saveVoiceProfiles([profile, second])
        let reloaded = AppStore(repository: store.repository)

        try reloaded.renameVoiceProfile(id: second.id, name: profile.name)

        XCTAssertEqual(reloaded.voiceProfiles.map(\.name), [profile.name, profile.name])
        XCTAssertEqual(reloaded.voiceProfiles.map(\.id), [profile.id, second.id])
        XCTAssertEqual(try store.repository.loadVoiceProfiles(), reloaded.voiceProfiles)
    }

    func test_rename_blankNameRetainsInputAndStoredProfile() throws {
        let (store, profile) = try fixture()
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        for blank in ["", " ", "\n\t", "\u{3000}"] {
            model.name = blank
            XCTAssertFalse(model.canSave)
            model.save()
            XCTAssertFalse(model.isClosed)
            XCTAssertEqual(model.name, blank)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(store.voiceProfiles, [profile])
            XCTAssertEqual(try store.repository.loadVoiceProfiles(), [profile])
        }
    }

    func test_rename_missingProfileDoesNotRecreateIt() throws {
        let (store, profile) = try fixture()
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        try store.deleteVoiceProfile(id: profile.id)
        model.name = "Renamed"
        model.save()
        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(model.name, "Renamed")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(store.voiceProfiles.isEmpty)
        XCTAssertTrue(try store.repository.loadVoiceProfiles().isEmpty)
    }

    func test_rename_writeFailureRetainsOldNameAndDraftThenAllowsRetry() throws {
        let (store, profile) = try fixture()
        let index = store.repository.sharedRootURL.appendingPathComponent("Voices/profiles.json")
        let backup = index.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        model.name = "Retry"
        model.save()

        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(model.name, "Retry")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(store.voiceProfiles, [profile])
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        XCTAssertEqual(try store.repository.loadVoiceProfiles(), [profile])

        model.save()
        XCTAssertTrue(model.isClosed)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.repository.loadVoiceProfiles().first?.name, "Retry")
    }

    func test_rename_cancelDiscardsDraftAndPreventsLaterSave() throws {
        let (store, profile) = try fixture()
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        model.name = "Cancelled draft"
        model.cancel()
        model.save()
        XCTAssertTrue(model.isClosed)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(store.voiceProfiles, [profile])
        XCTAssertEqual(try store.repository.loadVoiceProfiles(), [profile])
    }

    func test_rename_sameNameClosesWithoutChangingStoredIndex() throws {
        let (store, profile) = try fixture()
        let index = try Data(contentsOf: store.repository.sharedRootURL.appendingPathComponent("Voices/profiles.json"))
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        model.name = " \(profile.name) "
        model.save()
        XCTAssertTrue(model.isClosed)
        XCTAssertEqual(try Data(contentsOf: store.repository.sharedRootURL.appendingPathComponent("Voices/profiles.json")), index)
    }

    func test_renameView_showsExistingNameAndInlineFailure() async throws {
        let (store, profile) = try fixture()
        let model = VoiceProfileRenameModel(profile: profile, store: store)
        let view = NSHostingView(rootView: VoiceProfileRenameView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 448, height: 210),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(text(in: view).contains(profile.name))
        try snapshot(view, name: "rename")
        try store.deleteVoiceProfile(id: profile.id)
        model.name = "Retry name"
        model.save()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(text(in: view).contains("Retry name"))
        try snapshot(view, name: "rename-error")
        XCTAssertFalse(model.isClosed)
        XCTAssertNotNil(model.errorMessage)
    }

    /// Seeds only temporary metadata and synthetic bytes; renaming must never
    /// inspect audio, request a permission, or load a synthesis model.
    private func fixture() throws -> (AppStore, VoiceProfile) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-rename-\(UUID().uuidString)")
        let repository = ProjectRepository(rootURL: root)
        let profile = VoiceProfile(
            name: "Demo narrator", referenceFilename: "reference.wav",
            referenceText: "Synthetic reference", language: "english",
            consentConfirmed: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reference = try repository.prepareVoiceReferenceURL(
            profileID: profile.id, fileExtension: "wav"
        )
        try Data("synthetic reference bytes".utf8).write(to: reference.url)
        // Use the owned filename selected by the repository.
        var stored = profile
        stored.referenceFilename = reference.filename
        try repository.saveVoiceProfiles([stored])
        let project = DemoProject(
            name: "Synthetic project",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 5, width: 1280, height: 720),
            narrations: [NarrationClip(
                voiceProfileID: stored.id, filename: "narration.wav",
                text: "Synthetic narration", startTime: 0, duration: 1
            )]
        )
        try repository.saveProjects([project])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (AppStore(repository: repository), stored)
    }

    /// Reads the native text field used by the mounted rename form.
    private func text(in view: NSView) -> String {
        ([view as? NSTextField].compactMap { $0?.stringValue }
            + view.subviews.map { text(in: $0) }).joined(separator: "\n")
    }

    /// Captures only synthetic rename input and errors for visual review.
    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/voice-profile-rename")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
