import Darwin
import Foundation
import StorybirdCore

struct SubtitleImportResult: Codable {
    var project: DemoProject
    var revision: Int
    var added_ids: [UUID]
}

struct SubtitleExportResult: Codable {
    var path: String
    var revision: Int
    var caption_count: Int
    var scope: SRTCaptionScope
}

extension AppStore {
    /// Copies an opened regular file into a temporary snapshot, parses the whole
    /// UTF-8 SRT off the UI actor, and appends only after a fresh revision check.
    func importSubtitles(projectID: UUID, expectedRevision: Int, sourceURL: URL) async throws -> SubtitleImportResult {
        guard let initial = project(id: projectID) else { throw RecordingStoreError.projectNotFound }
        guard initial.revision == expectedRevision else { throw RecordingStoreError.revisionConflict(initial.revision) }
        let lease = beginStorageOperation(.importing)
        defer { endStorageOperation(lease) }
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached {
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("Storybird-SRT-\(UUID()).srt")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try LocalMediaFile.copy(from: sourceURL, to: snapshot)
            try Task.checkCancellation()
            return try SRTCaptions.parse(Data(contentsOf: snapshot, options: .mappedIfSafe))
        }
        let captions = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard var current = project(id: projectID) else { throw RecordingStoreError.projectNotFound }
        guard current.revision == expectedRevision else { throw RecordingStoreError.revisionConflict(current.revision) }
        current.subtitles += captions
        let saved = try saveProject(current, expectedRevision: expectedRevision)
        return SubtitleImportResult(project: saved, revision: saved.revision, added_ids: captions.map(\.id))
    }

    /// An explicit SRT output owns a new exclusive file. Existing destinations,
    /// imported originals and the project index are never overwritten.
    func exportSubtitles(projectID: UUID, scope: SRTCaptionScope, parentDirectory: URL) throws -> SubtitleExportResult {
        guard let project = project(id: projectID) else { throw RecordingStoreError.projectNotFound }
        guard parentDirectory.isFileURL else { throw AgentEditError.invalidField("parent_directory") }
        let access = parentDirectory.startAccessingSecurityScopedResource()
        defer { if access { parentDirectory.stopAccessingSecurityScopedResource() } }
        let properties = try parentDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard properties.isDirectory == true else { throw AgentEditError.invalidField("parent_directory") }
        let data = Data(try SRTCaptions.encode(project: project, scope: scope).utf8)
        let safeName = project.name.unicodeScalars.prefix(40).map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let destination = parentDirectory.appendingPathComponent("\(safeName.isEmpty ? "captions" : safeName)-\(UUID().uuidString.lowercased()).srt")
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            try output.write(contentsOf: data)
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return SubtitleExportResult(path: destination.path, revision: project.revision,
            caption_count: (scope == .cue ? 0 : project.subtitles.count) + (scope == .independent ? 0 : project.clicks.count), scope: scope)
    }
}
