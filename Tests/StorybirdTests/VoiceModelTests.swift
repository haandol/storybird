import Foundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class VoiceModelTests: XCTestCase {
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
                             voiceModelServices: [.base1_7B: large, .base0_6B: small])
        let original = store.projects
        XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
        try store.selectVoiceModel(.base0_6B)
        let reopened = AppStore(repository: repository, voiceModelPreferences: preferences)
        XCTAssertEqual(reopened.selectedVoiceModel, .base0_6B)
        XCTAssertEqual(store.projects, original)
        let largeCalls = await large.prepareCalls
        let smallCalls = await small.prepareCalls
        XCTAssertEqual(largeCalls, 0)
        XCTAssertEqual(smallCalls, 0)
        XCTAssertEqual(store.voiceModelSnapshot(.base0_6B).quantizationBits, 8)
    }

    func test_prepare_duplicateCallsShareWorkAndSelectionIsLockedUntilReady() async throws {
        let provider = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base0_6B: provider])
        try store.selectVoiceModel(.base0_6B)
        XCTAssertEqual(try store.startVoiceModelPreparation(.base0_6B).state, "preparing")
        XCTAssertEqual(try store.startVoiceModelPreparation(.base0_6B).state, "preparing")
        XCTAssertThrowsError(try store.selectVoiceModel(.base1_7B))
        try store.selectVoiceModel(.base0_6B)
        await waitFor { await provider.prepareCalls == 1 }
        await provider.finishPreparation()
        await waitFor { store.voiceRuntimeState == .ready }
        XCTAssertFalse(store.isVoiceModelBusy)
        XCTAssertEqual(try store.startVoiceModelPreparation(.base0_6B).state, "ready")
        let calls = await provider.prepareCalls
        XCTAssertEqual(calls, 1)
        try store.selectVoiceModel(.base1_7B)
        XCTAssertEqual(store.voiceRuntimeState, .notPrepared)
        XCTAssertEqual(store.voiceModelSnapshot(.base0_6B).state, "ready")
    }

    func test_failedPreparation_remainsObservableAndRetryPreservesOtherModel() async throws {
        let large = ModelTestProvider(ready: true)
        let small = ModelTestProvider(hold: true)
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()),
                             voiceModelServices: [.base1_7B: large, .base0_6B: small])
        await store.refreshVoiceRuntimeState()
        try store.selectVoiceModel(.base0_6B)
        _ = try store.startVoiceModelPreparation(.base0_6B)
        await waitFor { await small.prepareCalls == 1 }
        await small.finishPreparation(fail: true)
        await waitFor { store.voiceModelSnapshot(.base0_6B).state == "failed" }
        await store.refreshVoiceRuntimeState()
        XCTAssertEqual(store.voiceModelSnapshot(.base0_6B).state, "failed")
        XCTAssertNotNil(store.voiceModelSnapshot(.base0_6B).error)
        XCTAssertEqual(store.voiceModelSnapshot(.base1_7B).state, "ready")
        XCTAssertFalse(store.isVoiceModelBusy)
        await small.allowSuccess()
        await store.prepareVoiceRuntime()
        XCTAssertEqual(store.voiceModelSnapshot(.base0_6B).state, "ready")
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
        let small = VoiceSynthesisService(rootURL: root, model: .base0_6B)
        let largeReady = await large.prepared()
        let absentSmall = await small.prepared()
        XCTAssertTrue(largeReady)
        XCTAssertFalse(absentSmall)
        try installMarker(.base0_6B, marker: VoiceModel.base1_7B.repositoryID)
        let wrongSmall = await small.prepared()
        XCTAssertFalse(wrongSmall)
        try installMarker(.base0_6B, marker: VoiceModel.base0_6B.repositoryID)
        let smallReady = await small.prepared()
        let preservedLarge = await large.prepared()
        XCTAssertTrue(smallReady)
        XCTAssertTrue(preservedLarge)
    }

    func test_microphoneLease_rejectsModelSelectionWithoutChangingPreference() throws {
        let store = AppStore(repository: ProjectRepository(rootURL: try fixture()))
        let lease = try store.beginMicrophoneOperation()
        XCTAssertThrowsError(try store.selectVoiceModel(.base0_6B))
        XCTAssertEqual(store.selectedVoiceModel, .base1_7B)
        store.endStorageOperation(lease)
        try store.selectVoiceModel(.base0_6B)
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
        let small = VoiceSynthesisService(rootURL: root, model: .base0_6B)
        async let first = large.generate(text: "Synthetic", referenceAudioURL: root.appendingPathComponent("ref.wav"),
                                        referenceText: "Reference", language: "english",
                                        outputURL: root.appendingPathComponent("large.wav"))
        async let second = small.generate(text: "Synthetic", referenceAudioURL: root.appendingPathComponent("ref.wav"),
                                          referenceText: "Reference", language: "english",
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

actor ModelTestProvider: VoiceSynthesisProviding {
    private var ready: Bool
    private var hold: Bool
    private var failure = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var prepareCalls = 0
    private(set) var generationCalls = 0

    init(ready: Bool = false, hold: Bool = false) {
        self.ready = ready
        self.hold = hold
    }

    func prepared() -> Bool { ready }

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

    func generate(text: String, referenceAudioURL: URL, referenceText: String,
                  language: String, outputURL: URL) async throws -> VoiceSynthesisResult {
        guard ready else { throw VoiceSynthesisError.processFailed("Synthetic model is not prepared.") }
        generationCalls += 1
        try TestVideoFactory.makeToneWAV(at: outputURL, duration: 1)
        return VoiceSynthesisResult(duration: 1, sampleRate: 44_100)
    }
}
