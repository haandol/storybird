import Foundation
import StorybirdCore

enum VoiceSynthesisError: LocalizedError {
    case uvUnavailable
    case runtimeScriptMissing
    case processFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .uvUnavailable:
            return "Install uv before preparing the local voice model."
        case .runtimeScriptMissing:
            return "The bundled voice runtime script is missing."
        case let .processFailed(message):
            return "Local voice synthesis failed: \(message)"
        case .invalidResponse:
            return "The local voice runtime returned an invalid response."
        }
    }
}

struct VoiceSynthesisResult: Sendable {
    let duration: Double
    let sampleRate: Int
}

private final class CancellableVoiceProcess: @unchecked Sendable {
    let process = Process()

    /// Terminates only a running child so Swift Task cancellation cannot publish
    /// a result produced after the caller stopped waiting.
    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// All model instances share one slot so switching models cannot overlap a
/// download/load with another memory-heavy worker.
private final class VoiceWorkerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false

    /// Claims the shared slot atomically across independent model actors.
    func acquireIfAvailable() -> Bool {
        lock.withLock {
            guard !occupied else { return false }
            occupied = true
            return true
        }
    }

    /// Makes the slot available only after its worker has completed or exited.
    func release() { lock.withLock { occupied = false } }
}

protocol VoiceSynthesisProviding: Sendable {
    /// Reports whether the approved local runtime can synthesize without
    /// initiating model preparation.
    func prepared() async -> Bool

    /// Installs and downloads the local runtime only from an explicit UI or MCP
    /// preparation action, without an additional approval step.
    func prepare() async throws

    /// Writes one complete local WAV from an existing consented reference and
    /// returns the duration needed for project timeline validation.
    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult
}

actor VoiceSynthesisService: VoiceSynthesisProviding {
    static let modelID = VoiceModel.base1_7B.repositoryID

    private let rootURL: URL
    private let model: VoiceModel
    private static let workerSlot = VoiceWorkerSlot()

    /// Binds cache, marker and worker arguments to one supported model.
    init(rootURL: URL, model: VoiceModel = .base1_7B) {
        self.rootURL = rootURL
        self.model = model
    }

    var isPrepared: Bool {
        FileManager.default.isExecutableFile(
            atPath: pythonURL.path
        ) && (try? String(contentsOf: modelMarkerURL, encoding: .utf8))
            == model.repositoryID
    }

    /// Reports readiness from local executable and marker state only, so opening
    /// the studio never initiates a model-provider request.
    func prepared() -> Bool { isPrepared }

    /// Prepares the requested model from either UI or MCP, staging all files
    /// before replacing only that model's last complete installation.
    func prepare() async throws {
        try await acquireWorker()
        defer { Self.workerSlot.release() }
        guard let uv = Self.executable(named: "uv") else {
            throw VoiceSynthesisError.uvUnavailable
        }
        let stagingRoot = rootURL.appendingPathComponent(
            "VoiceRuntime.staging-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let stagingVenv = stagingRoot.appendingPathComponent(
            ".venv",
            isDirectory: true
        )
        let stagingPython = stagingVenv.appendingPathComponent("bin/python")
        let stagingCache = stagingRoot.appendingPathComponent(
            "ModelCache",
            isDirectory: true
        )
        _ = try await run(
            executable: uv,
            arguments: ["venv", stagingVenv.path]
        )
        _ = try await run(
            executable: uv,
            arguments: [
                "pip", "install",
                "--python", stagingPython.path,
                "mlx-audio[tts]==0.5.3",
                "soundfile",
            ]
        )
        let environment = Self.processEnvironment(
            modelCacheURL: stagingCache,
            allowNetwork: true
        )
        _ = try await run(
            executable: stagingPython.path,
            arguments: [try scriptURL().path, "prepare", "--model", model.repositoryID],
            environment: environment
        )
        try Data(model.repositoryID.utf8).write(
            to: stagingRoot.appendingPathComponent("model-ready.txt"),
            options: .atomic
        )
        try Self.replacePreparedRuntime(
            active: runtimeRootURL,
            staging: stagingRoot
        )
    }

    /// Generates one complete project-owned WAV from an existing local voice
    /// profile without opening a network listener or exposing the reference audio.
    func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        language: String,
        outputURL: URL
    ) async throws -> VoiceSynthesisResult {
        try await acquireWorker()
        defer { Self.workerSlot.release() }
        guard isPrepared else {
            throw VoiceSynthesisError.processFailed(
                "The voice model is not prepared."
            )
        }
        let environment = Self.processEnvironment(
            modelCacheURL: modelCacheURL,
            allowNetwork: false
        )
        let data = try await run(
            executable: pythonURL.path,
            arguments: [
                try scriptURL().path,
                "generate",
                "--model", model.repositoryID,
                "--text", text,
                "--ref-audio", referenceAudioURL.path,
                "--ref-text", referenceText,
                "--language", language,
                "--output", outputURL.path,
            ],
            environment: environment
        )
        let outputText = String(decoding: data, as: UTF8.self)
        guard let jsonLine = outputText
            .split(separator: "\n")
            .reversed()
            .first(where: { $0.trimmingCharacters(
                in: .whitespaces
            ).hasPrefix("{") }),
            let object = try JSONSerialization.jsonObject(
                with: Data(jsonLine.utf8)
            ) as? [String: Any],
            object["ok"] as? Bool == true,
            let duration = (object["duration"] as? NSNumber)?.doubleValue,
            let sampleRate = (object["sample_rate"] as? NSNumber)?.intValue
        else {
            throw VoiceSynthesisError.invalidResponse
        }
        return VoiceSynthesisResult(
            duration: duration,
            sampleRate: sampleRate
        )
    }

    /// Builds the subprocess environment so model preparation may download only
    /// after approval while every later synthesis is forced to use local files.
    static func processEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        modelCacheURL: URL,
        allowNetwork: Bool
    ) -> [String: String] {
        var environment = base
        environment["HF_HOME"] = modelCacheURL.path
        if !allowNetwork {
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        }
        return environment
    }

    /// Publishes a completely prepared runtime and restores the previous active
    /// directory if the final move cannot complete.
    static func replacePreparedRuntime(
        active: URL,
        staging: URL,
        fileManager: FileManager = .default
    ) throws {
        let backup = active
            .deletingLastPathComponent()
            .appendingPathComponent(
                "VoiceRuntime.backup-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let hadActive = fileManager.fileExists(atPath: active.path)
        if hadActive {
            try fileManager.moveItem(at: active, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: active)
            if hadActive {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if hadActive,
               !fileManager.fileExists(atPath: active.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: active)
            }
            throw error
        }
    }

    /// Drains both pipes while the worker runs so verbose output cannot block
    /// process exit. Cancellation waits for exit before releasing the worker slot.
    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Data {
        let child = CancellableVoiceProcess()
        let process = child.process
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            let outputReader = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let errorReader = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            do {
                while process.isRunning {
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
            } catch {
                child.terminate()
                await Task.detached { child.process.waitUntilExit() }.value
                _ = await outputReader.value
                _ = await errorReader.value
                throw error
            }
            let output = await outputReader.value
            let error = await errorReader.value
            guard process.terminationStatus == 0 else {
                throw VoiceSynthesisError.processFailed(
                    String(decoding: error, as: UTF8.self)
                )
            }
            return output
        } onCancel: {
            child.terminate()
        }
    }

    /// Resolves the bundled worker in an app and the repository resource during
    /// development so both paths execute the same local synthesis contract.
    private func scriptURL() throws -> URL {
        if let bundled = Bundle.main.url(
            forResource: "voice_runtime",
            withExtension: "py"
        ) {
            return bundled
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/voice_runtime.py")
        guard FileManager.default.fileExists(atPath: development.path) else {
            throw VoiceSynthesisError.runtimeScriptMissing
        }
        return development
    }

    /// Finds the local package runner in common Apple Silicon installations
    /// without invoking a shell or changing the user's environment.
    private static func executable(named name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".pyenv/shims/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if let match = candidates.first(
            where: { FileManager.default.isExecutableFile(atPath: $0) }
        ) {
            return match
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Serializes memory-heavy workers and model replacement while preserving
    /// cancellation for queued requests instead of launching concurrent models.
    private func acquireWorker() async throws {
        while true {
            try Task.checkCancellation()
            if Self.workerSlot.acquireIfAvailable() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private var runtimeRootURL: URL {
        rootURL.appendingPathComponent(model.runtimeDirectoryName, isDirectory: true)
    }

    private var pythonURL: URL {
        if let override = ProcessInfo.processInfo.environment[
            "STORYBIRD_VOICE_PYTHON"
        ] {
            return URL(fileURLWithPath: override)
        }
        return runtimeRootURL
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin/python")
    }

    private var modelCacheURL: URL {
        if let override = ProcessInfo.processInfo.environment[
            "STORYBIRD_VOICE_HF_HOME"
        ] {
            return URL(fileURLWithPath: override)
        }
        return runtimeRootURL.appendingPathComponent(
            "ModelCache",
            isDirectory: true
        )
    }

    private var modelMarkerURL: URL {
        runtimeRootURL.appendingPathComponent("model-ready.txt")
    }
}
