import Foundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class VoiceModelTests: XCTestCase {
    func test_refresh_otherModelPreparationDoesNotDiscardInstalledModelReadiness() async throws {
        let base = ModelTestProvider(ready: true)
        let custom = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: base, .customVoice1_7B: custom])
        await base.suspendReadiness()
        let refresh = Task { await store.refreshVoiceRuntimeState() }
        await waitFor { await base.readinessIsWaiting }
        _ = try store.startVoiceModelPreparation(.customVoice1_7B)
        await base.finishReadiness()
        await refresh.value
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "ready")
        await custom.finishPreparation()
        await waitFor { store.voiceModelSnapshot(.customVoice1_7B).state == "ready" }
    }

    func test_legacySelection_migratesToBaseAndRetainedFilesRemainRemovable() async throws {
        let root = try fixture()
        let suite = "legacy-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(VoiceModel.base0_6B.rawValue, forKey: "storybird.voiceModel")
        let legacy = root.appendingPathComponent(VoiceModel.base0_6B.runtimeDirectoryName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let sentinel = legacy.appendingPathComponent("partial-model")
        try Data("Existing download".utf8).write(to: sentinel)
        let store = AppStore(repository: ProjectRepository(rootURL: root),
                             voiceModelPreferences: VoiceModelPreferences(defaults: defaults))
        XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
        XCTAssertEqual(defaults.string(forKey: "storybird.voiceModel"), VoiceModel.base1_7B.rawValue)
        await store.refreshVoiceRuntimeState()
        XCTAssertTrue(store.hasLegacyVoiceModelFiles)
        XCTAssertTrue(store.listedVoiceModels.contains(.base0_6B))
        XCTAssertFalse(store.voiceModelSnapshot(.base0_6B).supportsGeneration)
        XCTAssertThrowsError(try store.selectVoiceModel(.base0_6B))
        XCTAssertThrowsError(try store.startVoiceModelPreparation(.base0_6B))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("Existing download".utf8))
        await store.removeVoiceRuntime(model: .base0_6B)
        XCTAssertFalse(store.hasLegacyVoiceModelFiles)
        XCTAssertEqual(store.listedVoiceModels, VoiceModel.allCases)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func test_refresh_startedBeforeRemovalCannotRestoreStaleReadyState() async throws {
        let provider = ModelTestProvider(ready: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: provider])
        await provider.suspendReadiness()
        let refresh = Task { await store.refreshVoiceRuntimeState() }
        await waitFor { await provider.readinessIsWaiting }
        await store.removeVoiceRuntime()
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
        await provider.finishReadiness()
        await refresh.value
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
    }

    func test_remove_cleanupFailureNeverPublishesPartiallyRemovedRuntimeAsReady() async throws {
        try requireIsolatedRuntime()
        let root = try fixture()
        let active = root.appendingPathComponent(VoiceModel.base1_7B.runtimeDirectoryName)
        let bin = active.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data(VoiceModel.base1_7B.repositoryID.utf8).write(to: active.appendingPathComponent("model-ready.txt"))
        let service = VoiceSynthesisService(rootURL: root)
        let before = await service.prepared()
        XCTAssertTrue(before)
        XCTAssertThrowsError(try VoiceSynthesisService.removeRuntime(at: active, files: FailingModelCleanup()))
        let after = await service.prepared()
        XCTAssertFalse(after)
        let cleanup = root.appendingPathComponent("\(active.lastPathComponent).removing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanup.path))
        try await service.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.path))
    }

    func test_remove_symlinkDoesNotDeleteExternalTarget() async throws {
        let root = try fixture()
        let external = try fixture()
        let sentinel = external.appendingPathComponent("keep")
        try Data("External files".utf8).write(to: sentinel)
        let active = root.appendingPathComponent(VoiceModel.base1_7B.runtimeDirectoryName)
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: external)
        let service = VoiceSynthesisService(rootURL: root)
        try await service.remove()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "External files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    func test_remove_blocksConflictingWorkAndPreservesSelectionAcrossReopen() async throws {
        let root = try fixture()
        let suite = "model-removal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoiceModelPreferences(defaults: defaults)
        let large = ModelTestProvider(ready: true)
        let small = ModelTestProvider(ready: true)
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository, voiceModelPreferences: preferences,
                             voiceModelServices: [.base1_7B: large, .customVoice1_7B: small])
        try store.selectVoiceModel(.customVoice1_7B)
        await store.refreshVoiceRuntimeState()
        await small.suspendRemoval()
        XCTAssertEqual(try store.startVoiceModelRemoval(.customVoice1_7B).state, "removing")
        XCTAssertEqual(try store.startVoiceModelRemoval(.customVoice1_7B).state, "removing")
        await store.refreshVoiceRuntimeState()
        XCTAssertEqual(store.voiceRuntimeState, .removing)
        XCTAssertThrowsError(try store.selectVoiceModel(.base1_7B))
        XCTAssertThrowsError(try store.startVoiceModelRemoval(.base1_7B))
        XCTAssertThrowsError(try store.startVoiceModelPreparation(.customVoice1_7B))
        XCTAssertFalse(store.chooseStorageFolder(nil))
        await waitFor { await small.removeCalls == 1 }
        await small.finishRemoval()
        await waitFor { store.voiceRuntimeState == .notPrepared }
        XCTAssertFalse(store.isVoiceModelBusy)
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "ready")
        XCTAssertEqual(store.selectedVoiceModel, .customVoice1_7B)
        let reopened = AppStore(repository: repository, voiceModelPreferences: preferences,
                                voiceModelServices: [.base1_7B: large, .customVoice1_7B: small])
        await reopened.refreshVoiceRuntimeState()
        XCTAssertEqual(reopened.selectedVoiceModel, .customVoice1_7B)
        XCTAssertEqual(reopened.voiceRuntimeState, .notPrepared)
        await store.removeVoiceRuntime()
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
        await store.prepareVoiceRuntime()
        XCTAssertEqual(store.voiceRuntimeState, .ready)
    }

    func test_remove_duringInstallationOrVoiceWork_rejectsWithoutDeletingFiles() async throws {
        let provider = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: provider])
        _ = try store.startVoiceModelPreparation(.base1_7B)
        XCTAssertThrowsError(try store.startVoiceModelRemoval(.base1_7B))
        XCTAssertThrowsError(try store.startVoiceModelRemoval(.customVoice1_7B))
        await waitFor { await provider.prepareCalls == 1 }
        await provider.finishPreparation()
        await waitFor { store.voiceRuntimeState == .ready }
        let lease = store.beginStorageOperation(.voice)
        XCTAssertThrowsError(try store.startVoiceModelRemoval(.base1_7B))
        store.endStorageOperation(lease)
        let calls = await provider.removeCalls
        XCTAssertEqual(calls, 0)
    }

    func test_remove_failureIsObservableAndRetryReleasesLease() async throws {
        let provider = ModelTestProvider(ready: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: provider])
        await provider.finishRemoval(fail: true)
        await store.removeVoiceRuntime()
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "failed")
        XCTAssertNotNil(store.voiceModelSnapshot(.base1_7B).error)
        await store.refreshVoiceRuntimeState()
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "failed")
        XCTAssertFalse(store.isVoiceModelBusy)
        await provider.finishRemoval()
        await store.removeVoiceRuntime()
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
        XCTAssertNil(store.voiceModelSnapshot(.base1_7B).error)
    }

    func test_remove_realRuntimeDeletesOnlyTargetAndRecoversInterruptedCleanup() async throws {
        try requireIsolatedRuntime()
        let root = try fixture()
        for model in VoiceModel.allCases {
            let runtime = root.appendingPathComponent(model.runtimeDirectoryName)
            let bin = runtime.appendingPathComponent(".venv/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let python = bin.appendingPathComponent("python")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try Data(model.repositoryID.utf8).write(to: runtime.appendingPathComponent("model-ready.txt"))
            try Data("Synthetic download".utf8).write(to: runtime.appendingPathComponent("weights"))
        }
        let protected = ["profiles.json", "reference.wav", "project.json", "completed.wav", "draft.wav"]
        for name in protected { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let small = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        let large = VoiceSynthesisService(rootURL: root, model: .base1_7B)
        try await small.remove()
        try await small.remove()
        let ready = await large.prepared()
        let removed = await small.prepared()
        XCTAssertTrue(ready)
        XCTAssertFalse(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(VoiceModel.customVoice1_7B.runtimeDirectoryName).path))
        for name in protected {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8))
        }
        let active = root.appendingPathComponent(VoiceModel.base1_7B.runtimeDirectoryName)
        let cleanup = root.appendingPathComponent("\(VoiceModel.base1_7B.runtimeDirectoryName).removing")
        try FileManager.default.moveItem(at: active, to: cleanup)
        let reopened = VoiceSynthesisService(rootURL: root, model: .base1_7B)
        let interrupted = await reopened.prepared()
        XCTAssertFalse(interrupted)
        try await reopened.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanup.path))
        do {
            _ = try await reopened.generate(text: "Synthetic", referenceAudioURL: root.appendingPathComponent("reference.wav"),
                                            referenceText: "Synthetic", language: "english",
                                            outputURL: root.appendingPathComponent("unexpected.wav"))
            XCTFail("Removed runtime must not synthesize.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected.wav").path))
    }

    func test_selection_persistsWithoutPreparingModelsOrChangingProjects() async throws {
        let root = try fixture()
        let suite = "storybird-voice-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VoiceModelPreferences(defaults: defaults)
        let large = ModelTestProvider()
        let small = ModelTestProvider()
        let repository = ProjectRepository(rootURL: root)
        let store = AppStore(repository: repository, voiceModelPreferences: preferences,
                             voiceModelServices: [.base1_7B: large, .customVoice1_7B: small])
        let original = store.projects
        XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
        try store.selectVoiceModel(.customVoice1_7B)
        let reopened = AppStore(repository: repository, voiceModelPreferences: preferences)
        XCTAssertEqual(reopened.selectedVoiceModel, .customVoice1_7B)
        XCTAssertEqual(store.projects, original)
        let largeCalls = await large.prepareCalls
        let smallCalls = await small.prepareCalls
        XCTAssertEqual(largeCalls, 0)
        XCTAssertEqual(smallCalls, 0)
        XCTAssertEqual(store.voiceModelSnapshot(.customVoice1_7B).quantizationBits, 8)
    }

    func test_prepare_duplicateCallsShareWorkAndSelectionIsLockedUntilReady() async throws {
        let provider = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.customVoice1_7B: provider])
        try store.selectVoiceModel(.customVoice1_7B)
        XCTAssertEqual(try store.startVoiceModelPreparation(.customVoice1_7B).state, "preparing")
        XCTAssertEqual(try store.startVoiceModelPreparation(.customVoice1_7B).state, "preparing")
        XCTAssertThrowsError(try store.selectVoiceModel(.base1_7B))
        try store.selectVoiceModel(.customVoice1_7B)
        await waitFor { await provider.prepareCalls == 1 }
        await provider.finishPreparation()
        await waitFor { store.voiceRuntimeState == .ready }
        XCTAssertFalse(store.isVoiceModelBusy)
        XCTAssertEqual(try store.startVoiceModelPreparation(.customVoice1_7B).state, "ready")
        let calls = await provider.prepareCalls
        XCTAssertEqual(calls, 1)
        try store.selectVoiceModel(.base1_7B)
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
        XCTAssertEqual(store.voiceModelSnapshot(.customVoice1_7B).state, "ready")
    }

    func test_failedPreparation_remainsObservableAndRetryPreservesOtherModel() async throws {
        let large = ModelTestProvider(ready: true)
        let small = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: large, .customVoice1_7B: small])
        await store.refreshVoiceRuntimeState()
        try store.selectVoiceModel(.customVoice1_7B)
        _ = try store.startVoiceModelPreparation(.customVoice1_7B)
        await waitFor { await small.prepareCalls == 1 }
        await small.finishPreparation(fail: true)
        await waitFor { store.voiceModelSnapshot(.customVoice1_7B).state == "failed" }
        await store.refreshVoiceRuntimeState()
        XCTAssertEqual(store.voiceModelSnapshot(.customVoice1_7B).state, "failed")
        XCTAssertNotNil(store.voiceModelSnapshot(.customVoice1_7B).error)
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "ready")
        XCTAssertFalse(store.isVoiceModelBusy)
        await small.allowSuccess()
        await store.prepareVoiceRuntime()
        XCTAssertEqual(store.voiceModelSnapshot(.customVoice1_7B).state, "ready")
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "ready")
    }

    func test_existingLargeInstallation_isReusedAndCannotMarkSmallModelReady() async throws {
        try requireIsolatedRuntime()
        let root = try fixture()
        func installMarker(_ model: VoiceModel, marker: String) throws {
            let runtime = root.appendingPathComponent(model.runtimeDirectoryName)
            let bin = runtime.appendingPathComponent(".venv/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let python = bin.appendingPathComponent("python")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try Data(marker.utf8).write(to: runtime.appendingPathComponent("model-ready.txt"))
        }
        try installMarker(.base1_7B, marker: VoiceModel.base1_7B.repositoryID)
        let large = VoiceSynthesisService(rootURL: root, model: .base1_7B)
        let small = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        let largeReady = await large.prepared()
        let absentSmall = await small.prepared()
        XCTAssertTrue(largeReady)
        XCTAssertFalse(absentSmall)
        try installMarker(.customVoice1_7B, marker: VoiceModel.base1_7B.repositoryID)
        let wrongSmall = await small.prepared()
        XCTAssertFalse(wrongSmall)
        try installMarker(.customVoice1_7B, marker: VoiceModel.customVoice1_7B.repositoryID)
        let smallReady = await small.prepared()
        let preservedLarge = await large.prepared()
        XCTAssertTrue(smallReady)
        XCTAssertTrue(preservedLarge)
    }

    func test_microphoneLease_rejectsModelSelectionWithoutChangingPreference() throws {
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()))
        let lease = try store.beginMicrophoneOperation()
        XCTAssertThrowsError(try store.selectVoiceModel(.customVoice1_7B))
        XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
        store.endStorageOperation(lease)
        try store.selectVoiceModel(.customVoice1_7B)
    }

    func test_modelWorkers_shareExecutionSlotAndPassDistinctModelsOffline() async throws {
        try requireIsolatedRuntime()
        let root = try fixture()
        // A tiny local worker fails if both model actors run at once. It records
        // only its model arguments and offline/cache settings, never user input.
        let worker = """
        #!/bin/sh
        fixture_runtime=$(cd "$(dirname "$0")/../.." && pwd)
        fixture_root=$(cd "$fixture_runtime/.." && pwd)
        mkdir "$fixture_root/worker-lock" || exit 72
        trap 'rmdir "$fixture_root/worker-lock"' EXIT
        printf '%s\\n' "$@" > "$fixture_runtime/arguments.txt"
        printf '%s\\n' "$HF_HUB_OFFLINE" "$TRANSFORMERS_OFFLINE" "$HF_HOME" > "$fixture_runtime/environment.txt"
        sleep 0.2
        printf '{"ok":true,"duration":1,"sample_rate":24000}\\n'
        """
        for model in VoiceModel.allCases {
            let runtime = root.appendingPathComponent(model.runtimeDirectoryName)
            let bin = runtime.appendingPathComponent(".venv/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appendingPathComponent("python")
            try Data(worker.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try Data(model.repositoryID.utf8).write(to: runtime.appendingPathComponent("model-ready.txt"))
        }
        let large = VoiceSynthesisService(rootURL: root, model: .base1_7B)
        let small = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        async let first = large.generate(text: "Synthetic", referenceAudioURL: root.appendingPathComponent("ref.wav"),
                                        referenceText: "Reference", language: "english",
                                        outputURL: root.appendingPathComponent("large.wav"))
        async let second = small.generateCustomVoice(text: "Synthetic", speaker: "sohee", instruct: "Warm narration", language: "english",
                                          outputURL: root.appendingPathComponent("small.wav"))
        _ = try await (first, second)
        for model in VoiceModel.allCases {
            let runtime = root.appendingPathComponent(model.runtimeDirectoryName)
            let arguments = try String(contentsOf: runtime.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertTrue(arguments.contains("--model\n\(model.repositoryID)\n"))
            let environment = try String(contentsOf: runtime.appendingPathComponent("environment.txt"), encoding: .utf8)
            XCTAssertTrue(environment.hasPrefix("1\n1\n"))
            XCTAssertTrue(environment.contains(runtime.appendingPathComponent("ModelCache").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-lock").path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storybird-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func requireIsolatedRuntime() throws {
        guard ProcessInfo.processInfo.environment["STORYBIRD_VOICE_PYTHON"] == nil,
              ProcessInfo.processInfo.environment["STORYBIRD_VOICE_HF_HOME"] == nil else {
            throw XCTSkip("Uses only isolated model runtimes, never configured live overrides.")
        }
    }

    private func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Voice model did not reach its expected terminal state.")
    }
}

private final class FailingModelCleanup: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

actor ModelTestProvider: VoiceModelRemoving, CustomVoiceSynthesisProviding {
    private var ready: Bool
    private var hold: Bool
    private var failure = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var prepareCalls = 0
    private(set) var generationCalls = 0
    private(set) var removeCalls = 0
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var holdRemoval = false
    private var failRemoval = false
    private var holdReadiness = false
    private var readinessContinuation: CheckedContinuation<Void, Never>?
    var readinessIsWaiting: Bool { readinessContinuation != nil }

    init(ready: Bool = false, hold: Bool = false) {
        self.ready = ready
        self.hold = hold
    }

    /// Captures readiness before suspension so tests can deliver a stale reply.
    func prepared() async -> Bool {
        let snapshot = ready
        if holdReadiness {
            await withCheckedContinuation { readinessContinuation = $0 }
        }
        return snapshot
    }

    /// Holds the next query while another model operation changes app state.
    func suspendReadiness() { holdReadiness = true }

    /// Releases that query with the snapshot it captured before the change.
    func finishReadiness() {
        holdReadiness = false
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    func prepare() async throws {
        prepareCalls += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        if failure { throw NSError(domain: "SyntheticModelDownload", code: 1) }
        ready = true
    }

    func finishPreparation(fail: Bool = false) {
        failure = fail
        hold = false
        continuation?.resume()
        continuation = nil
    }

    func allowSuccess() { failure = false }

    /// Keeps removal pending while tests inspect duplicate and conflicting requests.
    func suspendRemoval() { holdRemoval = true }

    /// Simulates a removal job without accessing any installed model directory.
    func remove() async throws {
        removeCalls += 1
        if holdRemoval { await withCheckedContinuation { removalContinuation = $0 } }
        if failRemoval { throw NSError(domain: "SyntheticModelRemoval", code: 1) }
        ready = false
    }

    /// Completes the held removal, optionally exposing a retryable failure.
    func finishRemoval(fail: Bool = false) {
        failRemoval = fail
        holdRemoval = false
        removalContinuation?.resume()
        removalContinuation = nil
    }

    private(set) var lastCustomVoice: CustomVoiceOptions?
    private(set) var lastText: String?
    private(set) var lastLanguage: String?
    private var generationFailure = false
    private var holdGeneration = false
    private var generationContinuation: CheckedContinuation<Void, Never>?
    var generationIsWaiting: Bool { generationContinuation != nil }

    /// Lets a test change the project revision before synthesis returns.
    func suspendGeneration() { holdGeneration = true }

    /// Releases synthesis or injects a failure before a synthetic WAV is written.
    func finishGeneration(fail: Bool = false) {
        generationFailure = fail
        holdGeneration = false
        generationContinuation?.resume()
        generationContinuation = nil
    }

    /// Records source inputs and writes a tone, isolating model behavior from
    /// tests of metadata, revision checks and repository failure.
    func generateCustomVoice(text: String, speaker: String, instruct: String,
                             language: String, outputURL: URL) async throws -> VoiceSynthesisResult {
        guard ready, let speaker = CustomVoiceSpeaker(rawValue: speaker) else {
            throw VoiceSynthesisError.processFailed("Synthetic CustomVoice model is not prepared.")
        }
        if holdGeneration { await withCheckedContinuation { generationContinuation = $0 } }
        if generationFailure { throw VoiceSynthesisError.processFailed("Synthetic generation failure.") }
        generationCalls += 1
        lastCustomVoice = CustomVoiceOptions(speaker: speaker, instruct: instruct)
        lastText = text; lastLanguage = language
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 1)
        return VoiceSynthesisResult(duration: 1, sampleRate: 44_100)
    }

    func generate(text: String, referenceAudioURL: URL, referenceText: String,
                  language: String, outputURL: URL) async throws -> VoiceSynthesisResult {
        guard ready else { throw VoiceSynthesisError.processFailed("Synthetic model is not prepared.") }
        generationCalls += 1
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 1)
        return VoiceSynthesisResult(duration: 1, sampleRate: 44_100)
    }
}
