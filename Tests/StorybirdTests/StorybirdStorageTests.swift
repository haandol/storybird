import AVFoundation
import Foundation
import StorybirdCore
import StorybirdMCPKit
@testable import Storybird
import XCTest

@MainActor
final class StorybirdStorageTests: XCTestCase {
    private func fixture() throws -> (URL, ProjectRepository, StorybirdStoragePreferences) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-storage-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let repository = ProjectRepository(rootURL: root.appendingPathComponent("default", isDirectory: true))
        try repository.prepare()
        let domain = "storybird.storage.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        return (root, repository, StorybirdStoragePreferences(defaults: defaults))
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_switchAndRestart_restoreSelectedLibraryWithoutMovingPreviousFiles() throws {
        let (root, repository, preferences) = try fixture()
        let old = DemoProject(
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try repository.saveProjects([old])
        let originalData = try Data(contentsOf: repository.rootURL.appendingPathComponent("library.json"))
        let store = AppStore(repository: repository, storagePreferences: preferences)
        let custom = try folder("custom", in: root)

        XCTAssertTrue(store.chooseStorageFolder(custom))
        XCTAssertTrue(store.projects.isEmpty)
        let newID = store.createProject(name: "New folder project")
        let reloaded = AppStore(repository: repository, storagePreferences: preferences)
        XCTAssertEqual(reloaded.repository.rootURL, custom)
        XCTAssertEqual(reloaded.projects.map(\.id), [newID])
        XCTAssertEqual(reloaded.selectedStorageRootURL, custom)
        XCTAssertEqual(try Data(contentsOf: repository.rootURL.appendingPathComponent("library.json")), originalData)

        XCTAssertTrue(reloaded.chooseStorageFolder(nil))
        XCTAssertEqual(reloaded.projects, [old])
        XCTAssertNil(preferences.selectedRootURL)
        XCTAssertTrue(reloaded.chooseStorageFolder(custom))
        XCTAssertEqual(reloaded.projects.map(\.id), [newID])
    }

    func test_corruptAndMissingFolders_preserveSelectionAndProjects() throws {
        let (root, repository, preferences) = try fixture()
        let custom = try folder("valid", in: root)
        let store = AppStore(repository: repository, storagePreferences: preferences)
        XCTAssertTrue(store.chooseStorageFolder(custom))
        let id = store.createProject()
        let malformed = try folder("malformed", in: root)
        let badIndex = malformed.appendingPathComponent("library.json")
        let bytes = Data("not a project library".utf8)
        try bytes.write(to: badIndex)

        for target in [malformed, root.appendingPathComponent("missing"), badIndex] {
            XCTAssertFalse(store.chooseStorageFolder(target))
            XCTAssertEqual(store.repository.rootURL, custom)
            XCTAssertEqual(store.selectedProjectID, id)
            XCTAssertEqual(preferences.selectedRootURL, custom)
            XCTAssertNotNil(store.storageErrorMessage)
        }
        XCTAssertEqual(try Data(contentsOf: badIndex), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }

    func test_readOnlyFolder_rejectsSelectionAfterActualWriteProbe() throws {
        let (root, repository, _) = try fixture()
        let target = try folder("read-only", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        let store = AppStore(repository: repository)
        XCTAssertFalse(store.chooseStorageFolder(target))
        XCTAssertEqual(store.repository.rootURL, repository.rootURL)
        XCTAssertNotNil(store.storageErrorMessage)
    }

    func test_restartWithMissingFolder_preservesChoiceAndPreventsProjectWrites() throws {
        let (root, repository, preferences) = try fixture()
        let missing = root.appendingPathComponent("disconnected", isDirectory: true)
        preferences.save(missing)
        let store = AppStore(repository: repository, storagePreferences: preferences)

        XCTAssertEqual(store.repository.rootURL, missing)
        XCTAssertEqual(store.selectedStorageRootURL, missing)
        XCTAssertNotNil(store.storageErrorMessage)
        XCTAssertThrowsError(try store.repository.saveProjects([]))
        XCTAssertThrowsError(try store.repository.prepareVideoRecordingURL(projectID: UUID()))
        XCTAssertThrowsError(try store.repository.prepareNarrationURL(projectID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(preferences.selectedRootURL, missing)

        _ = try folder("disconnected", in: root)
        XCTAssertTrue(store.chooseStorageFolder(missing))
        XCTAssertNil(store.storageErrorMessage)
        XCTAssertNoThrow(try store.repository.saveProjects([]))
    }

    func test_restartWithCorruptFolder_neverOverwritesTheIndex() throws {
        let (root, repository, preferences) = try fixture()
        let custom = try folder("corrupt", in: root)
        let index = custom.appendingPathComponent("library.json")
        let bytes = Data("{bad".utf8)
        try bytes.write(to: index)
        preferences.save(custom)
        let store = AppStore(repository: repository, storagePreferences: preferences)

        XCTAssertNotNil(store.storageErrorMessage)
        XCTAssertThrowsError(try store.repository.saveProjects([]))
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertTrue(store.chooseStorageFolder(nil))
        XCTAssertNil(preferences.selectedRootURL)
        XCTAssertEqual(try Data(contentsOf: index), bytes)
    }

    func test_switch_preservesSharedVoicesAndRuntimeButPlacesNarrationInProjectFolder() throws {
        let (root, repository, preferences) = try fixture()
        let profile = VoiceProfile(
            name: "Shared voice",
            referenceFilename: "reference.wav",
            referenceText: "Shared reference",
            language: "korean",
            consentConfirmed: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let reference = try repository.prepareVoiceReferenceURL(profileID: profile.id, fileExtension: "wav")
        let bytes = Data("synthetic reference".utf8)
        try bytes.write(to: reference.url)
        try repository.saveVoiceProfiles([profile])
        let runtime = try folder("VoiceRuntime", in: repository.rootURL)
        let marker = runtime.appendingPathComponent("ready")
        try bytes.write(to: marker)
        let store = AppStore(repository: repository, storagePreferences: preferences)
        let custom = try folder("custom", in: root)

        XCTAssertTrue(store.chooseStorageFolder(custom))
        XCTAssertEqual(store.voiceProfiles, [profile])
        XCTAssertEqual(store.repository.sharedRootURL, repository.rootURL)
        XCTAssertEqual(store.repository.voiceReferenceURL(profileID: profile.id, filename: reference.filename), reference.url)
        let projectID = UUID()
        let narration = try store.repository.prepareNarrationURL(projectID: projectID)
        let movie = try store.repository.prepareVideoRecordingURL(projectID: projectID)
        XCTAssertTrue(narration.url.path.hasPrefix(custom.path + "/Assets/"))
        XCTAssertTrue(movie.url.path.hasPrefix(custom.path + "/Assets/"))
        XCTAssertEqual(try Data(contentsOf: reference.url), bytes)
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("Voices").path))

        let reloaded = AppStore(repository: repository, storagePreferences: preferences)
        XCTAssertEqual(reloaded.voiceProfiles, [profile])
        try reloaded.deleteVoiceProfile(id: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_overlappingOperations_blockUntilEveryMatchingTokenEnds() throws {
        let (root, repository, preferences) = try fixture()
        let store = AppStore(repository: repository, storagePreferences: preferences)
        let custom = try folder("custom", in: root)
        let tokens = [
            store.beginStorageOperation(.recording),
            store.beginStorageOperation(.importing),
            store.beginStorageOperation(.voice),
            store.beginStorageOperation(.externalCommand),
        ]
        for token in tokens {
            XCTAssertFalse(store.chooseStorageFolder(custom))
            XCTAssertFalse(store.chooseStorageFolder(nil))
            XCTAssertEqual(store.repository.rootURL, repository.rootURL)
            XCTAssertNil(preferences.selectedRootURL)
            store.endStorageOperation(UUID())
            XCTAssertNotNil(store.storageChangeDisabledReason)
            store.endStorageOperation(token)
            store.endStorageOperation(token)
        }
        XCTAssertNil(store.storageChangeDisabledReason)
        XCTAssertTrue(store.chooseStorageFolder(custom))
    }

    func test_export_blocksFolderChangeUntilCompletion() throws {
        let (root, repository, _) = try fixture()
        let store = AppStore(repository: repository)
        let custom = try folder("custom", in: root)
        let export = try store.beginExport()
        XCTAssertFalse(store.chooseStorageFolder(custom))
        store.endExport(UUID())
        XCTAssertFalse(store.chooseStorageFolder(custom))
        store.endExport(export)
        XCTAssertTrue(store.chooseStorageFolder(custom))
    }

    func test_voicePreparation_blocksFolderChangeAcrossSuspensionAndReleasesOnFailure() async throws {
        let (root, repository, _) = try fixture()
        let voice = SuspendedStorageVoiceService()
        let store = AppStore(repository: repository, voiceService: voice)
        let custom = try folder("custom", in: root)
        let task = Task { await store.prepareVoiceRuntime() }
        await voice.waitUntilPreparing()
        XCTAssertFalse(store.chooseStorageFolder(custom))
        await voice.finish()
        await task.value
        XCTAssertTrue(store.chooseStorageFolder(custom))
    }

    func test_candidateWithMissingMediaOrDuplicateProjectIDs_isRejected() throws {
        let (root, repository, _) = try fixture()
        let custom = try folder("custom", in: root)
        let target = ProjectRepository(rootURL: custom)
        let movie = DemoProject(name: "Missing video", recording: VideoRecordingAsset(
            filename: "missing.mp4", duration: 1, width: 100, height: 100
        ))
        try target.saveProjects([movie])
        let store = AppStore(repository: repository)
        XCTAssertFalse(store.chooseStorageFolder(custom))

        let duplicate = DemoProject(name: "Duplicate")
        try target.saveProjects([duplicate, duplicate])
        XCTAssertFalse(store.chooseStorageFolder(custom))
        XCTAssertEqual(store.repository.rootURL, repository.rootURL)
    }

    func test_disconnectedActiveRoot_doesNotGetRecreatedByRecordingOrNarration() throws {
        let (root, repository, _) = try fixture()
        let custom = try folder("custom", in: root)
        let store = AppStore(repository: repository)
        XCTAssertTrue(store.chooseStorageFolder(custom))
        try FileManager.default.removeItem(at: custom)

        XCTAssertThrowsError(try store.repository.prepareVideoRecordingURL(projectID: UUID()))
        XCTAssertThrowsError(try store.repository.prepareNarrationURL(projectID: UUID()))
        XCTAssertThrowsError(try store.repository.saveProjects([]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
    }

    func test_importNarrationExportAndMCP_useSelectedProjectsAndSharedVoice() async throws {
        let (root, repository, preferences) = try fixture()
        let voice = StorageToneVoiceService()
        let store = AppStore(repository: repository, voiceService: voice, storagePreferences: preferences)
        let source = root.appendingPathComponent("synthetic.mp4")
        _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
        let reference = root.appendingPathComponent("synthetic.wav")
        try TestVideoFactory.makeToneWAV(at: reference, duration: 1)
        let profile = try await store.importVoiceProfile(
            name: "Synthetic", sourceURL: reference, transcript: "Test",
            consentConfirmed: true
        )
        let custom = try folder("custom", in: root)
        XCTAssertTrue(store.chooseStorageFolder(custom))
        let projectID = try await store.importVideo(from: source)
        let project = try await store.generateNarration(
            projectID: projectID, expectedRevision: 0, voiceProfileID: profile.id,
            text: "Synthetic narration", language: "korean", startTime: 0
        )
        let usedReference = await voice.lastReference
        XCTAssertEqual(usedReference, repository.voiceReferenceURL(
            profileID: profile.id, filename: profile.referenceFilename
        ))
        XCTAssertTrue(store.repository.assetURL(
            projectID: projectID, filename: project.narrations[0].filename
        ).path.hasPrefix(custom.path + "/Assets/"))
        let output = root.appendingPathComponent("export.mp4")
        _ = try await LayeredVideoExporter().export(
            project: project,
            sourceURL: store.repository.assetURL(
                projectID: projectID,
                filename: try XCTUnwrap(project.recording).filename
            ),
            destinationURL: output,
            progress: { _ in }
        )
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)

        let host = StorybirdExternalControlHost(store: store)
        let request = StorybirdControlRequest(
            name: "storybird_list_projects", argumentsJSON: Data("{}".utf8)
        )
        let listed = await host.handle(request)
        XCTAssertFalse(listed.isError)
        XCTAssertTrue(listed.text.lowercased().contains(projectID.uuidString.lowercased()))
        XCTAssertTrue(store.chooseStorageFolder(nil))
        let defaultList = await host.handle(request)
        XCTAssertFalse(defaultList.text.lowercased().contains(projectID.uuidString.lowercased()))
        XCTAssertTrue(store.chooseStorageFolder(custom))
        XCTAssertEqual(store.projects.first?.narrations.count, 1)
        XCTAssertEqual(store.voiceProfiles.map(\.id), [profile.id])
        XCTAssertThrowsError(try store.undo(projectID: projectID)) { error in
            XCTAssertEqual(error as? RecordingStoreError, .noUndo)
        }
    }

    func test_failedImport_releasesStorageLockAndPublishesNothing() async throws {
        let (root, repository, _) = try fixture()
        let store = AppStore(repository: repository)
        do {
            _ = try await store.importVideo(from: root.appendingPathComponent("absent.mp4"))
            XCTFail("Missing input must fail")
        } catch {}
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNil(store.storageChangeDisabledReason)
        XCTAssertTrue(store.chooseStorageFolder(try folder("custom", in: root)))
    }
}

private actor StorageToneVoiceService: VoiceSynthesisProviding {
    private(set) var lastReference: URL?
    func prepared() async -> Bool { true }
    func prepare() async throws {}
    func generate(
        text: String, referenceAudioURL: URL, referenceText: String,
        language: String, outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        lastReference = referenceAudioURL
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 0.5)
        return VoiceSynthesisResult(duration: 0.5, sampleRate: 44_100)
    }
}

private actor SuspendedStorageVoiceService: VoiceSynthesisProviding {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?

    func prepared() async -> Bool { false }

    func prepare() async throws {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { finishWaiter = $0 }
        throw VoiceSynthesisError.invalidResponse
    }

    func waitUntilPreparing() async {
        if !started {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }

    func finish() {
        finishWaiter?.resume()
        finishWaiter = nil
    }

    func generate(
        text: String, referenceAudioURL: URL, referenceText: String,
        language: String, outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        throw VoiceSynthesisError.invalidResponse
    }
}
