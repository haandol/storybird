import Foundation
import StorybirdCore

struct MediaImportRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case video, audio }
    let kind: Kind
    let path: String
    let projectID: UUID?
    let key: String
}

struct MediaImportResult: Codable, Equatable, Sendable {
    let projectID: UUID
    let assetID: UUID?
    let duration: Double
    let width: Int?
    let height: Int?
    let revision: Int?
}

struct MediaImportJob: Codable, Sendable {
    enum State: String, Codable, Sendable { case importing, completed, failed, cancelled }
    let id: UUID
    let request: MediaImportRequest
    let reservedProjectID: UUID
    let reservedAssetID: UUID
    var state: State = .importing
    var result: MediaImportResult?
    var error: String?
    var cleanupPending: Bool?
}

struct MediaImportStatus: Codable, Sendable {
    let jobID: UUID
    let state: MediaImportJob.State
    let kind: MediaImportRequest.Kind
    let result: MediaImportResult?
    let error: String?
    let cleanupPending: Bool

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state, kind, result, error
        case cleanupPending = "cleanup_pending"
    }
}

enum MediaImportError: LocalizedError {
    case conflictingKey, missingJob, invalidJournal

    var errorDescription: String? {
        switch self {
        case .conflictingKey: return "This idempotency_key already identifies a different import."
        case .missingJob: return "The import job does not exist in the selected library."
        case .invalidJournal: return "The selected library's import job records are invalid."
        }
    }
}

@MainActor
final class MediaImportController {
    private unowned let store: AppStore
    private var loadedRoot: URL?
    private var jobs: [MediaImportJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var dirty = false
    private let beforeCleanup: ((MediaImportJob) throws -> Void)?
    private let beforeImport: ((MediaImportJob) async throws -> Void)?

    /// One controller belongs to the app store, so reconnecting or replacing the
    /// MCP host cannot create a second worker for an already accepted import.
    init(
        store: AppStore,
        beforeCleanup: ((MediaImportJob) throws -> Void)? = nil,
        beforeImport: ((MediaImportJob) async throws -> Void)? = nil
    ) {
        self.store = store
        self.beforeCleanup = beforeCleanup
        self.beforeImport = beforeImport
    }

    /// Saves a request and reserved result identities before starting I/O. Replays
    /// consult that record before accessing the source, including after it moved.
    func start(kind: MediaImportRequest.Kind, path: String, projectID: UUID?, key: String) throws -> MediaImportStatus {
        let source = try LocalMediaFile.url(path: path)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (kind == .audio) == (projectID != nil) else {
            throw AgentEditError.invalidField("idempotency_key or project_id")
        }
        try load()
        retryCleanup()
        try flush()
        let request = MediaImportRequest(kind: kind, path: source.path, projectID: projectID, key: key)
        if let job = jobs.first(where: { $0.request.key == key }) {
            guard job.request == request else { throw MediaImportError.conflictingKey }
            return status(job)
        }
        if let projectID, store.project(id: projectID) == nil {
            throw RecordingStoreError.projectNotFound
        }
        let job = MediaImportJob(
            id: UUID(), request: request, reservedProjectID: projectID ?? UUID(), reservedAssetID: UUID()
        )
        jobs.append(job)
        dirty = true
        do {
            try flush()
        } catch {
            jobs.removeLast()
            dirty = false
            throw error
        }
        let lease = store.beginStorageOperation(.importing)
        tasks[job.id] = Task { [self] in
            defer {
                tasks[job.id] = nil
                store.endStorageOperation(lease)
            }
            var finished = job
            do {
                try Task.checkCancellation()
                try await beforeImport?(job)
                try Task.checkCancellation()
                switch request.kind {
                case .video:
                    _ = try await store.importVideo(from: source, projectID: job.reservedProjectID)
                case .audio:
                    _ = try await store.importProjectAudio(
                        projectID: job.reservedProjectID, sourceURL: source, assetID: job.reservedAssetID
                    )
                }
                finished.result = try publishedResult(for: job)
                finished.state = .completed
            } catch is CancellationError {
                finished.state = .cancelled
            } catch {
                finished.state = .failed
                finished.error = error.localizedDescription
            }
            do {
                try cleanAbandoned(finished)
                finished.cleanupPending = false
            } catch {
                finished.cleanupPending = true
                store.errorMessage = "Import cleanup needs retry: \(error.localizedDescription)"
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = finished
                dirty = true
                do { try flush() }
                catch { store.errorMessage = "Import status could not be saved: \(error.localizedDescription)" }
            }
        }
        return status(job)
    }

    /// Reads the selected library's durable outcome. An unsaved terminal state is
    /// not reported as complete; a later call can retry only the metadata write.
    func get(id: UUID) throws -> MediaImportStatus {
        try load()
        retryCleanup()
        try flush()
        guard let job = jobs.first(where: { $0.id == id }) else { throw MediaImportError.missingJob }
        return status(job)
    }

    /// Requests cooperative cancellation and leaves publication to the worker.
    /// Completed/failed/cancelled jobs retain their original outcome.
    func cancel(id: UUID) throws -> MediaImportStatus {
        // Cancellation must reach a known worker even when another job has a
        // journal write waiting for retry. Status persistence may still fail.
        tasks[id]?.cancel()
        return try get(id: id)
    }

    /// Selects a library journal and recovers only abandoned work. Reserved IDs
    /// reconcile a library commit followed by a crash before the job-state write.
    private func load() throws {
        let root = store.repository.rootURL.standardizedFileURL
        guard loadedRoot != root else { return }
        guard tasks.isEmpty else { throw RepositoryError.storageUnavailable("An import is still running.") }
        if dirty { try flush() }
        try store.repository.prepare()
        let url = root.appendingPathComponent("media-imports.json")
        var recovered = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([MediaImportJob].self, from: Data(contentsOf: url)) : []
        guard Set(recovered.map(\.id)).count == recovered.count,
              Set(recovered.map(\.request.key)).count == recovered.count else {
            throw MediaImportError.invalidJournal
        }
        let needsRecovery = recovered.contains { $0.state == .importing || $0.cleanupPending == true }
        for index in recovered.indices where recovered[index].state == .importing {
            let job = recovered[index]
            if let result = try? publishedResult(for: job) {
                recovered[index].result = result
                recovered[index].state = .completed
                recovered[index].cleanupPending = true
            } else {
                recovered[index].state = .failed
                recovered[index].error = "Import was interrupted. Use a new idempotency_key to retry."
                recovered[index].cleanupPending = true
            }
        }
        for index in recovered.indices where recovered[index].cleanupPending == true {
            do {
                try cleanAbandoned(recovered[index])
                recovered[index].cleanupPending = false
            } catch {
                store.errorMessage = "Import cleanup needs retry: \(error.localizedDescription)"
            }
        }
        if needsRecovery {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recovered).write(to: url, options: .atomic)
        }
        jobs = recovered
        loadedRoot = root
        dirty = false
    }

    /// Keeps the journal within its owning library and retains failed writes for
    /// retry. Project publication uses the existing atomic library writer.
    private func flush() throws {
        guard dirty, let root = loadedRoot else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: root.appendingPathComponent("media-imports.json"), options: .atomic)
        dirty = false
    }

    /// Resolves only the pre-reserved identity; source paths are never reread to
    /// guess whether a completed import must be executed again.
    private func publishedResult(for job: MediaImportJob) throws -> MediaImportResult {
        guard let project = store.project(id: job.reservedProjectID) else {
            throw RecordingStoreError.projectNotFound
        }
        switch job.request.kind {
        case .video:
            guard let video = project.recording else { throw VideoProjectValidationError.missingRecording }
            return MediaImportResult(projectID: project.id, assetID: nil, duration: video.duration,
                                     width: video.width, height: video.height, revision: 0)
        case .audio:
            guard let asset = project.audioAssets.first(where: { $0.id == job.reservedAssetID }) else {
                throw AgentEditError.invalidField("asset_id")
            }
            return MediaImportResult(projectID: project.id, assetID: asset.id, duration: asset.duration,
                                     width: nil, height: nil, revision: nil)
        }
    }

    /// Removes unpublished media and audio snapshots independently. A registered
    /// WAV stays playable even when removal of its temporary snapshot needs retry.
    private func cleanAbandoned(_ job: MediaImportJob) throws {
        try beforeCleanup?(job)
        switch job.request.kind {
        case .video:
            if store.project(id: job.reservedProjectID) == nil {
                try store.repository.removeProjectAssets(projectID: job.reservedProjectID)
            }
        case .audio:
            let filename = "narration-\(job.reservedAssetID.uuidString.lowercased()).wav"
            let published = store.project(id: job.reservedProjectID)?
                .availableAudioAssets.contains(where: { $0.filename == filename }) == true
            let url = store.repository.assetURL(projectID: job.reservedProjectID, filename: filename)
            let snapshot = url.deletingLastPathComponent()
                .appendingPathComponent(".\(filename).source.\(URL(fileURLWithPath: job.request.path).pathExtension.lowercased())")
            let partials = published ? [snapshot] : [url, snapshot]
            for partial in partials where FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
        }
    }

    /// Retries only removal of unpublished files. A cleanup failure never
    /// restarts the import or changes a terminal job's outcome.
    private func retryCleanup() {
        for index in jobs.indices where jobs[index].cleanupPending == true {
            do {
                try cleanAbandoned(jobs[index])
                jobs[index].cleanupPending = false
                dirty = true
            } catch {
                store.errorMessage = "Import cleanup needs retry: \(error.localizedDescription)"
            }
        }
    }

    /// Exposes operation metadata and committed results without leaking reserved
    /// IDs as if partially copied media were already available to edit.
    private func status(_ job: MediaImportJob) -> MediaImportStatus {
        MediaImportStatus(jobID: job.id, state: job.state, kind: job.request.kind,
                          result: job.state == .completed ? job.result : nil, error: job.error,
                          cleanupPending: job.cleanupPending == true)
    }
}
