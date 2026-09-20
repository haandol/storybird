import Foundation
import StorybirdCore
import XCTest
@testable import Storybird

@MainActor
final class CustomVoiceRuntimeTests: XCTestCase {
    func test_cloneAndCustomVoice_shareWorkerAndUseDistinctOfflineInputs() async throws {
        let root = try fixture()
        for model in VoiceModel.allCases {
            try installWorker(at: root, model: model)
        }
        let base = VoiceSynthesisService(rootURL: root)
        let custom = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        async let cloneResult = base.generate(
            text: "Clone text", referenceAudioURL: root.appendingPathComponent("reference.wav"),
            referenceText: "Reference text", language: "english",
            outputURL: root.appendingPathComponent("clone.wav")
        )
        async let customResult = custom.generateCustomVoice(
            text: "기본 목소리", speaker: "Sohee", instruct: "Calm and clear.",
            language: "korean", outputURL: root.appendingPathComponent("custom.wav")
        )
        let results = try await (cloneResult, customResult)
        XCTAssertEqual(results.0.duration, 1)
        XCTAssertEqual(results.1.duration, 1)
        XCTAssertEqual(results.1.sampleRate, 24_000)
        for model in VoiceModel.allCases {
            let runtime = runtimeURL(root, model)
            let arguments = try String(contentsOf: runtime.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertTrue(arguments.contains("--model\n\(model.repositoryID)\n"))
            if model == .base1_7B {
                XCTAssertTrue(arguments.contains("--ref-text\nReference text\n"))
                XCTAssertTrue(arguments.contains("--ref-audio\n"))
                XCTAssertFalse(arguments.contains("--speaker\n"))
                XCTAssertFalse(arguments.contains("--instruct\n"))
            } else {
                XCTAssertTrue(arguments.contains("--speaker\nSohee\n--instruct\nCalm and clear.\n"))
                XCTAssertTrue(arguments.contains("--language\nkorean\n"))
                XCTAssertFalse(arguments.contains("--ref-audio\n"))
                XCTAssertFalse(arguments.contains("--ref-text\n"))
            }
            let environment = try String(contentsOf: runtime.appendingPathComponent("environment.txt"), encoding: .utf8)
            XCTAssertEqual(environment, "1\n1\n\(runtime.appendingPathComponent("ModelCache").path)\n")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-lock").path))
    }

    func test_customVoice_emptyInstructionIsPassedExplicitly() async throws {
        let root = try fixture()
        try installWorker(at: root, model: .customVoice1_7B)
        let service = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        _ = try await service.generateCustomVoice(
            text: "Hello", speaker: "ryan", instruct: "", language: "english",
            outputURL: root.appendingPathComponent("custom.wav")
        )
        let arguments = try String(
            contentsOf: runtimeURL(root, .customVoice1_7B).appendingPathComponent("arguments.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(arguments.hasSuffix("--speaker\nryan\n--instruct\n\n"))
    }

    func test_wrongModelOrUnknownSpeaker_failsBeforeWorkerLaunch() async throws {
        let root = try fixture()
        for model in VoiceModel.manageableModels {
            try installWorker(at: root, model: model)
            let service = VoiceSynthesisService(rootURL: root, model: model)
            if model != .base1_7B {
                do {
                    _ = try await service.generate(
                        text: "Hello", referenceAudioURL: root.appendingPathComponent("reference.wav"),
                        referenceText: "Reference", language: "english",
                        outputURL: root.appendingPathComponent("clone.wav")
                    )
                    XCTFail("Cloning must reject \(model).")
                } catch let error as VoiceSynthesisError {
                    guard case .processFailed = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
            do {
                _ = try await service.generateCustomVoice(
                    text: "Hello", speaker: model == .customVoice1_7B ? "unknown" : "ryan",
                    instruct: "", language: "english", outputURL: root.appendingPathComponent("custom.wav")
                )
                XCTFail("Invalid CustomVoice input must fail.")
            } catch let error as VoiceSynthesisError {
                guard case .processFailed = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: runtimeURL(root, model).appendingPathComponent("arguments.txt").path
            ))
        }
    }

    func test_customVoice_cancellationReleasesSlotOnlyAfterWorkerExit() async throws {
        let root = try fixture()
        try installWorker(at: root, model: .base1_7B)
        try installWorker(at: root, model: .customVoice1_7B, hold: true)
        let base = VoiceSynthesisService(rootURL: root)
        let custom = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        let generation = Task {
            try await custom.generateCustomVoice(
                text: "Hello", speaker: "ryan", instruct: "", language: "english",
                outputURL: root.appendingPathComponent("custom.wav")
            )
        }
        defer { generation.cancel() }
        let lock = root.appendingPathComponent("worker-lock")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: lock.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        do {
            try await base.remove()
            XCTFail("Removal must not run while CustomVoice owns the worker.")
        } catch let error as VoiceSynthesisError {
            guard case .processFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let queued = Task {
            try await base.generate(
                text: "Hello", referenceAudioURL: root.appendingPathComponent("reference.wav"),
                referenceText: "Reference", language: "english",
                outputURL: root.appendingPathComponent("clone.wav")
            )
        }
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("The cancelled queued worker must not run.")
        } catch is CancellationError {}
        generation.cancel()
        do {
            _ = try await generation.value
            XCTFail("Cancelled generation must not publish a result.")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtimeURL(root, .base1_7B).appendingPathComponent("arguments.txt").path
        ))
        try await custom.remove()
        let remains = await custom.hasInstalledFiles()
        XCTAssertFalse(remains)
        let baseReady = await base.prepared()
        XCTAssertTrue(baseReady)
    }

    func test_partialAndDanglingInstalls_remainDiscoverableAndRemovable() async throws {
        let root = try fixture()
        for model in VoiceModel.manageableModels {
            let service = VoiceSynthesisService(rootURL: root, model: model)
            let active = runtimeURL(root, model)
            let cleanup = root.appendingPathComponent("\(active.lastPathComponent).removing")
            for path in [active, cleanup] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let partial = await service.hasInstalledFiles()
                let ready = await service.prepared()
                XCTAssertTrue(partial)
                XCTAssertFalse(ready)
                try await service.remove()
                try FileManager.default.createSymbolicLink(
                    at: path, withDestinationURL: root.appendingPathComponent("missing-target")
                )
                let dangling = await service.hasInstalledFiles()
                XCTAssertTrue(dangling)
                try await service.remove()
                XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: path.path))
            }
            try await service.remove()
            let remains = await service.hasInstalledFiles()
            XCTAssertFalse(remains)
        }
    }

    func test_removalOfSymlink_preservesItsTargetAndOtherModels() async throws {
        let root = try fixture()
        try installWorker(at: root, model: .base1_7B)
        let target = runtimeURL(root, .base1_7B)
        let custom = VoiceSynthesisService(rootURL: root, model: .customVoice1_7B)
        try FileManager.default.createSymbolicLink(
            at: runtimeURL(root, .customVoice1_7B), withDestinationURL: target
        )
        try await custom.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("model-ready.txt").path))
        let remains = await custom.hasInstalledFiles()
        XCTAssertFalse(remains)
    }

    private func fixture() throws -> URL {
        guard ProcessInfo.processInfo.environment["STORYBIRD_VOICE_PYTHON"] == nil,
              ProcessInfo.processInfo.environment["STORYBIRD_VOICE_HF_HOME"] == nil else {
            throw XCTSkip("Requires isolated fake workers, never live runtime overrides.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-custom-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func runtimeURL(_ root: URL, _ model: VoiceModel) -> URL {
        root.appendingPathComponent(model.runtimeDirectoryName)
    }

    private func installWorker(at root: URL, model: VoiceModel, hold: Bool = false) throws {
        let runtime = runtimeURL(root, model)
        let bin = runtime.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("python")
        let script = """
        #!/bin/sh
        fixture_runtime=$(cd "$(dirname "$0")/../.." && pwd)
        fixture_root=$(cd "$fixture_runtime/.." && pwd)
        mkdir "$fixture_root/worker-lock" || exit 72
        trap 'rmdir "$fixture_root/worker-lock"' EXIT
        trap 'exit 0' TERM
        printf '%s\\n' "$@" > "$fixture_runtime/arguments.txt"
        printf '%s\\n' "$HF_HUB_OFFLINE" "$TRANSFORMERS_OFFLINE" "$HF_HOME" > "$fixture_runtime/environment.txt"
        \(hold ? "while :; do sleep 0.05; done" : "sleep 0.1")
        printf 'Synthetic worker log\\n{"ok":true,"duration":1,"sample_rate":24000}\\n'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(model.repositoryID.utf8).write(to: runtime.appendingPathComponent("model-ready.txt"))
    }
}
