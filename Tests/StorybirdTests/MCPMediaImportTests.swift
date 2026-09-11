import AVFoundation
import Darwin
import Foundation
import MCP
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

@MainActor
final class MCPMediaImportTests: XCTestCase {
    /// Executes the public MCP handlers through an SDK client without touching the
    /// real socket, capture permissions, microphone or user's library.
    private func withFixture(_ body: (Client, AppStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: ProjectRepository(rootURL: root.appendingPathComponent("library")))
        let host = StorybirdExternalControlHost(store: store)
        let ipc = StorybirdAppIPCClient(sender: { await host.handle($0) }, launcher: {
            throw MediaImportError.missingJob
        })
        let server = await StorybirdMCPService(client: ipc).makeServer()
        let transport = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transport.server)
        let client = Client(name: "Import fixture", version: "1")
        do {
            _ = try await client.connect(transport: transport.client)
            try await body(client, store, root)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Decodes real wire JSON so a tool declaration alone cannot satisfy coverage.
    private func call<T: Decodable>(_ client: Client, _ name: String, _ args: [String: Value]) async throws -> T {
        let response = try await client.callTool(name: name, arguments: args)
        XCTAssertNotEqual(response.isError, true, "\(response.content)")
        guard case let .text(text, _, _) = try XCTUnwrap(response.content.first) else {
            throw MediaImportError.missingJob
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    /// Bounds the wait and requires an observed terminal outcome.
    private func terminal(_ client: Client, _ job: MediaImportStatus) async throws -> MediaImportStatus {
        for _ in 0..<1_000 {
            let current: MediaImportStatus = try await call(client, "storybird_get_import", [
                "job_id": .string(job.jobID.uuidString),
            ])
            if current.state != .importing { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import did not reach a terminal state.")
        throw MediaImportError.missingJob
    }

    func test_videoImport_mp4AndMOVPreserveSourceAudioAndCreateEditableProjectsWithoutApproval() async throws {
        try await withFixture { client, store, root in
            for ext in ["mp4", "mov"] {
                let source = root.appendingPathComponent("External demo.\(ext)")
                _ = try await TestVideoFactory.makeMovie(
                    at: source, fileType: ext == "mov" ? .mov : .mp4, includeAudio: true, duration: 2
                )
                let original = try Data(contentsOf: source)
                let args: [String: Value] = ["path": .string(source.path), "idempotency_key": .string(ext)]
                let started: MediaImportStatus = try await call(client, "storybird_import_video", args)
                XCTAssertNil(started.result)
                let done = try await terminal(client, started)
                XCTAssertEqual(done.state, .completed)
                let result = try XCTUnwrap(done.result)
                let project = try XCTUnwrap(store.project(id: result.projectID))
                XCTAssertEqual(project.revision, 0)
                XCTAssertEqual(project.clips.count, 1)
                XCTAssertTrue(project.clicks.isEmpty && project.subtitles.isEmpty && project.effects.isEmpty)
                XCTAssertEqual(result.duration, project.recording?.duration)
                XCTAssertEqual(result.revision, 0)
                let owned = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
                XCTAssertEqual(try Data(contentsOf: owned), original)
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertNil(store.externalControlPrompt)
                try FileManager.default.removeItem(at: source)
                let replay: MediaImportStatus = try await call(client, "storybird_import_video", args)
                XCTAssertEqual(replay.jobID, started.jobID)
                XCTAssertEqual(replay.result, result)
                let tracks = try await AVURLAsset(url: owned).loadTracks(withMediaType: .audio)
                XCTAssertEqual(tracks.count, 1)
                let amplitude = try await TestVideoFactory.averageAmplitude(in: owned, from: 0.1, to: 1)
                XCTAssertGreaterThan(amplitude, 0)
                let edit: DemoProject = try await call(client, "storybird_get_project", ["project_id": .string(project.id.uuidString)])
                XCTAssertEqual(edit.id, project.id)
            }
            XCTAssertEqual(store.projects.count, 2)
        }
    }

    func test_audioImport_registersOnceWithoutRevisionThenSupportsPlacementStaleRejectionAndUndo() async throws {
        try await withFixture { client, store, root in
            let video = root.appendingPathComponent("picture.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false, duration: 3)
            let projectID = try await store.importVideo(from: video)
            let source = root.appendingPathComponent("External audio.wav")
            try TestVideoFactory.makeToneWAV(at: source, duration: 1)
            let original = try Data(contentsOf: source)
            let args: [String: Value] = [
                "path": .string(source.path), "project_id": .string(projectID.uuidString), "idempotency_key": "voice",
            ]
            let started: MediaImportStatus = try await call(client, "storybird_import_audio", args)
            let replay: MediaImportStatus = try await call(client, "storybird_import_audio", args)
            XCTAssertEqual(started.jobID, replay.jobID)
            let done = try await terminal(client, started)
            XCTAssertEqual(done.state, .completed)
            let assetID = try XCTUnwrap(done.result?.assetID)
            XCTAssertEqual(store.project(id: projectID)?.revision, 0)
            XCTAssertEqual(store.project(id: projectID)?.audioAssets.count, 1)
            XCTAssertEqual(store.project(id: projectID)?.narrations.count, 0)
            XCTAssertEqual(done.result?.duration, 1)
            let placed: DemoProject = try await call(client, "storybird_place_audio_asset", [
                "project_id": .string(projectID.uuidString), "asset_id": .string(assetID.uuidString),
                "expected_revision": 0, "start_time": 1,
            ])
            XCTAssertEqual(placed.revision, 1)
            let stale = try await client.callTool(name: "storybird_place_audio_asset", arguments: [
                "project_id": .string(projectID.uuidString), "asset_id": .string(assetID.uuidString),
                "expected_revision": 0, "start_time": 0,
            ])
            XCTAssertEqual(stale.isError, true)
            let invalid = try await client.callTool(name: "storybird_place_audio_asset", arguments: [
                "project_id": .string(projectID.uuidString), "asset_id": .string(assetID.uuidString),
                "expected_revision": 1, "start_time": 3,
            ])
            XCTAssertEqual(invalid.isError, true)
            XCTAssertEqual(store.project(id: projectID)?.narrations.count, 1)
            let undone: DemoProject = try await call(client, "storybird_undo_project", [
                "project_id": .string(projectID.uuidString), "expected_revision": 1,
            ])
            XCTAssertTrue(undone.narrations.isEmpty)
            XCTAssertEqual(undone.audioAssets.count, 1)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertNil(store.externalControlPrompt)
        }
    }

    func test_importReplay_conflictingInputsAndInvalidSchemasDoNotPublishAdditionalMedia() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("demo.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let started: MediaImportStatus = try await call(client, "storybird_import_video", [
                "path": .string(source.path), "idempotency_key": "same",
            ])
            let conflict = try await client.callTool(name: "storybird_import_video", arguments: [
                "path": .string(root.appendingPathComponent("other.mp4").path), "idempotency_key": "same",
            ])
            XCTAssertEqual(conflict.isError, true)
            for args: [String: Value] in [
                ["path": .string(source.path)],
                ["path": true, "idempotency_key": "bad"],
                ["path": .string(source.path), "idempotency_key": "   "],
                ["path": "relative.mp4", "idempotency_key": "relative"],
                ["path": "https://example.invalid/movie.mp4", "idempotency_key": "url"],
                ["path": .string(source.path), "idempotency_key": "extra", "approval": true],
            ] {
                let result = try await client.callTool(name: "storybird_import_video", arguments: args)
                XCTAssertEqual(result.isError, true)
            }
            let done = try await terminal(client, started)
            XCTAssertEqual(done.state, .completed)
            XCTAssertEqual(store.projects.count, 1)
            let missing = try await client.callTool(name: "storybird_import_audio", arguments: [
                "path": .string(source.path), "idempotency_key": "no-project", "project_id": .string(UUID().uuidString),
            ])
            XCTAssertEqual(missing.isError, true)
        }
    }

    func test_invalidMedia_missingCorruptDirectoryFIFOAndAudioOnlyVideoFailWithoutPublication() async throws {
        try await withFixture { client, store, root in
            let corrupt = root.appendingPathComponent("corrupt.mp4")
            try Data("not video".utf8).write(to: corrupt)
            let directory = root.appendingPathComponent("directory.mp4")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fifo = root.appendingPathComponent("pipe.mp4")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            let audioOnly = root.appendingPathComponent("audio-only.mp4")
            try await TestVideoFactory.makeAudioOnlyMovie(at: audioOnly)
            let unsupported = root.appendingPathComponent("bad.txt")
            try Data("not supported".utf8).write(to: unsupported)
            for (index, source) in [corrupt, directory, fifo, audioOnly, unsupported, root.appendingPathComponent("missing.mp4")].enumerated() {
                let started: MediaImportStatus = try await call(client, "storybird_import_video", [
                    "path": .string(source.path), "idempotency_key": .string("invalid-\(index)"),
                ])
                let done = try await terminal(client, started)
                XCTAssertEqual(done.state, .failed)
                XCTAssertNil(done.result)
                XCTAssertNotNil(done.error)
            }
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.rootURL.appendingPathComponent("Assets").path).isEmpty)
        }
    }

    func test_importCancellation_isTerminalAndReleasesStorageLeaseWithoutCreatingProject() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("cancel.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            // Same actor turn prevents the worker from running before cancellation.
            let started = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "cancel")
            XCTAssertNotNil(store.storageChangeDisabledReason)
            XCTAssertFalse(store.chooseStorageFolder(root))
            _ = try store.mediaImports.cancel(id: started.jobID)
            let done = try await terminal(client, started)
            XCTAssertEqual(done.state, .cancelled)
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertNil(store.storageChangeDisabledReason)
            let replay = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "cancel")
            XCTAssertEqual(replay.state, .cancelled)
            let secondCancel: MediaImportStatus = try await call(client, "storybird_cancel_import", [
                "job_id": .string(started.jobID.uuidString),
            ])
            XCTAssertEqual(secondCancel.state, .cancelled)
        }
    }

    func test_importLibrarySaveFailure_preservesOriginalAndRemovesPartialVideo() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("save.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let original = try Data(contentsOf: source)
            try FileManager.default.createDirectory(
                at: store.repository.rootURL.appendingPathComponent("library.json"), withIntermediateDirectories: false
            )
            let started: MediaImportStatus = try await call(client, "storybird_import_video", [
                "path": .string(source.path), "idempotency_key": "save-failure",
            ])
            let done = try await terminal(client, started)
            XCTAssertEqual(done.state, .failed)
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.rootURL.appendingPathComponent("Assets").path).isEmpty)
        }
    }

    func test_importRestart_reconcilesCommittedResultAndFailsAbandonedWorkWithoutReexecution() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("restart.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let started: MediaImportStatus = try await call(client, "storybird_import_video", [
                "path": .string(source.path), "idempotency_key": "restart",
            ])
            let done = try await terminal(client, started)
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            var jobs = try JSONDecoder().decode([MediaImportJob].self, from: Data(contentsOf: journal))
            jobs[0].state = .importing
            jobs[0].result = nil
            let abandoned = MediaImportJob(id: UUID(),
                request: MediaImportRequest(kind: .video, path: source.path, projectID: nil, key: "abandoned"),
                reservedProjectID: UUID(), reservedAssetID: UUID())
            let partial = try store.repository.prepareImportedVideoURL(projectID: abandoned.reservedProjectID, fileExtension: "mp4")
            try Data("partial".utf8).write(to: partial.url)
            jobs.append(abandoned)
            try JSONEncoder().encode(jobs).write(to: journal, options: .atomic)
            try FileManager.default.removeItem(at: source)
            let restarted = AppStore(repository: store.repository)
            let replay = try restarted.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "restart")
            XCTAssertEqual(replay.jobID, done.jobID)
            XCTAssertEqual(replay.state, .completed)
            XCTAssertEqual(replay.result, done.result)
            let failed = try restarted.mediaImports.get(id: abandoned.id)
            XCTAssertEqual(failed.state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.url.path))
            XCTAssertEqual(restarted.projects.count, 1)
        }
    }

    func test_audioImportRestart_preservesAssetAndCleansOnlyUnpublishedReservedFiles() async throws {
        try await withFixture { client, store, root in
            let video = root.appendingPathComponent("audio-restart.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false)
            let projectID = try await store.importVideo(from: video)
            let source = root.appendingPathComponent("audio-restart.wav")
            try TestVideoFactory.makeToneWAV(at: source, duration: 0.5)
            let started: MediaImportStatus = try await call(client, "storybird_import_audio", [
                "path": .string(source.path), "project_id": .string(projectID.uuidString), "idempotency_key": "audio",
            ])
            let done = try await terminal(client, started)
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            var jobs = try JSONDecoder().decode([MediaImportJob].self, from: Data(contentsOf: journal))
            jobs[0].state = .importing
            jobs[0].result = nil
            let abandoned = MediaImportJob(id: UUID(),
                request: MediaImportRequest(kind: .audio, path: source.path, projectID: projectID, key: "abandoned-audio"),
                reservedProjectID: projectID, reservedAssetID: UUID())
            let partial = try store.repository.prepareNarrationURL(projectID: projectID, assetID: abandoned.reservedAssetID)
            try Data("partial".utf8).write(to: partial.url)
            let snapshot = partial.url.deletingLastPathComponent()
                .appendingPathComponent(".\(partial.filename).source.wav")
            try Data("snapshot".utf8).write(to: snapshot)
            jobs.append(abandoned)
            try JSONEncoder().encode(jobs).write(to: journal, options: .atomic)
            try FileManager.default.removeItem(at: source)
            let restarted = AppStore(repository: store.repository)
            let replay = try restarted.mediaImports.start(kind: .audio, path: source.path, projectID: projectID, key: "audio")
            XCTAssertEqual(replay.result, done.result)
            XCTAssertEqual(replay.state, .completed)
            XCTAssertEqual(try restarted.mediaImports.get(id: abandoned.id).state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
            let project = try XCTUnwrap(restarted.project(id: projectID))
            XCTAssertEqual(project.audioAssets.count, 1)
            XCTAssertEqual(project.revision, 0)
            XCTAssertGreaterThan(try ProjectAudioFiles.inspect(
                restarted.repository.assetURL(projectID: projectID, filename: project.audioAssets[0].filename)
            ).peak, 0)
        }
    }

    func test_importJournalWriteFailure_doesNotStartWorkerOrPublishReservedProject() async throws {
        try await withFixture { _, store, root in
            let source = root.appendingPathComponent("journal.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            XCTAssertThrowsError(try store.mediaImports.get(id: UUID()))
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            if FileManager.default.fileExists(atPath: journal.path) {
                try FileManager.default.removeItem(at: journal)
            }
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "write-fail"))
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertNil(store.storageChangeDisabledReason)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.rootURL.appendingPathComponent("Assets").path).isEmpty)
        }
    }

    func test_importLibrarySelection_keepsReplayKeysWithTheirOriginalLibrary() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("folder.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let args: [String: Value] = ["path": .string(source.path), "idempotency_key": "folder"]
            let started: MediaImportStatus = try await call(client, "storybird_import_video", args)
            let done = try await terminal(client, started)
            let other = root.appendingPathComponent("other-library")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            XCTAssertTrue(store.chooseStorageFolder(other))
            XCTAssertThrowsError(try store.mediaImports.get(id: done.jobID))
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertTrue(store.chooseStorageFolder(nil))
            let replay = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "folder")
            XCTAssertEqual(replay.jobID, done.jobID)
            XCTAssertEqual(replay.result, done.result)
            XCTAssertEqual(store.projects.count, 1)
            store.deleteProject(id: done.result!.projectID)
            let deleted = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "folder")
            XCTAssertEqual(deleted.result, done.result)
            XCTAssertTrue(store.projects.isEmpty, "Replaying a completed import must not resurrect a deleted project.")
        }
    }

    func test_audioImport_cancellationAndCorruptInputLeaveExistingProjectAndUndoIntact() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("bad.wav")
            try Data("not audio".utf8).write(to: source)
            let video = root.appendingPathComponent("existing.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false)
            let id = try await store.importVideo(from: video)
            let before = try XCTUnwrap(store.project(id: id))
            let cancelled = try store.mediaImports.start(kind: .audio, path: source.path, projectID: id, key: "cancel-audio")
            _ = try store.mediaImports.cancel(id: cancelled.jobID)
            let cancelledResult = try await terminal(client, cancelled)
            XCTAssertEqual(cancelledResult.state, .cancelled)
            let corrupt: MediaImportStatus = try await call(client, "storybird_import_audio", [
                "path": .string(source.path), "project_id": .string(id.uuidString), "idempotency_key": "bad-audio",
            ])
            let corruptResult = try await terminal(client, corrupt)
            XCTAssertEqual(corruptResult.state, .failed)
            XCTAssertEqual(store.project(id: id), before)
            let files = try FileManager.default.contentsOfDirectory(atPath: store.repository.assetsDirectory(projectID: id).path)
            XCTAssertEqual(files, [before.recording!.filename])
        }
    }

    func test_importCompletionJournalFailure_reportsErrorUntilStatusCanBeSavedWithoutDuplicatingProject() async throws {
        try await withFixture { _, store, root in
            let source = root.appendingPathComponent("completion.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let started = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "completion")
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            try FileManager.default.removeItem(at: journal)
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            for _ in 0..<1_000 {
                if store.storageChangeDisabledReason == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(store.storageChangeDisabledReason)
            XCTAssertEqual(store.projects.count, 1)
            XCTAssertThrowsError(try store.mediaImports.get(id: started.jobID))
            try FileManager.default.removeItem(at: journal)
            let completed = try store.mediaImports.get(id: started.jobID)
            XCTAssertEqual(completed.state, .completed)
            let replay = try store.mediaImports.start(kind: .video, path: source.path, projectID: nil, key: "completion")
            XCTAssertEqual(replay.result, completed.result)
            XCTAssertEqual(store.projects.count, 1)
        }
    }

    func test_audioImport_mp3AndM4APassProductionProtocolAndProduceIndependentWAVs() async throws {
        try await withFixture { client, store, root in
            let video = root.appendingPathComponent("compressed.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false)
            let projectID = try await store.importVideo(from: video)
            let mp3 = root.appendingPathComponent("speech.mp3")
            try TestVideoFactory.makeMP3(at: mp3, duration: 1)
            let wav = root.appendingPathComponent("speech-source.wav")
            try TestVideoFactory.makeToneWAV(at: wav, duration: 1)
            let m4a = root.appendingPathComponent("speech.m4a")
            let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
            exporter.outputURL = m4a
            exporter.outputFileType = .m4a
            await exporter.export()
            XCTAssertEqual(exporter.status, .completed)
            for source in [mp3, m4a] {
                let original = try Data(contentsOf: source)
                let started: MediaImportStatus = try await call(client, "storybird_import_audio", [
                    "path": .string(source.path), "project_id": .string(projectID.uuidString),
                    "idempotency_key": .string(source.lastPathComponent),
                ])
                let done = try await terminal(client, started)
                XCTAssertEqual(done.state, .completed)
                let project = try XCTUnwrap(store.project(id: projectID))
                let asset = try XCTUnwrap(project.audioAssets.first { $0.id == done.result?.assetID })
                XCTAssertEqual(asset.origin, .imported)
                XCTAssertTrue(asset.filename.hasSuffix(".wav"))
                XCTAssertEqual(asset.duration, 1, accuracy: 0.1)
                XCTAssertEqual(try Data(contentsOf: source), original)
                try FileManager.default.removeItem(at: source)
                let summary = try ProjectAudioFiles.inspect(store.repository.assetURL(projectID: projectID, filename: asset.filename))
                XCTAssertGreaterThan(summary.peak, 0)
            }
            XCTAssertEqual(store.project(id: projectID)?.revision, 0)
            XCTAssertNil(store.externalControlPrompt)
        }
    }

    func test_importStatus_reopeningCompletedJournalDoesNotRewriteIt() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("read-only.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            let started: MediaImportStatus = try await call(client, "storybird_import_video", [
                "path": .string(source.path), "idempotency_key": "read-only",
            ])
            let done = try await terminal(client, started)
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            let oldDate = Date(timeIntervalSince1970: 1_000)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: journal.path)
            let reopened = AppStore(repository: store.repository)
            XCTAssertEqual(try reopened.mediaImports.get(id: done.jobID).state, .completed)
            let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
        }
    }

    func test_videoCancellation_afterCopyWritesBytesPreservesSourceAndPublishesNothing() async throws {
        try await withFixture { _, store, root in
            let source = root.appendingPathComponent("mid-copy.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
            var original = try Data(contentsOf: source)
            original.append(Data(repeating: 0, count: 3_145_728))
            try original.write(to: source)
            let cancellation = ImportCancellationProbe()
            let parent = Task {
                try await store.importVideo(from: source, didCopyBytes: { bytes in
                    if bytes > 0 { cancellation.progress() }
                })
            }
            cancellation.set { parent.cancel() }
            do {
                _ = try await parent.value
                XCTFail("Expected cancellation after a real copied chunk.")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(cancellation.events, 1, "Parent cancellation must stop copying before the next chunk.")
            XCTAssertTrue(store.projects.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.repository.rootURL.appendingPathComponent("Assets").path).isEmpty)
            XCTAssertNil(store.storageChangeDisabledReason)
        }
    }

    func test_audioCancellation_afterDecodingFramesRemovesWAVAndSnapshotWithoutChangingProject() async throws {
        try await withFixture { _, store, root in
            let source = root.appendingPathComponent("mid-decode.wav")
            try TestVideoFactory.makeToneWAV(at: source, duration: 1)
            let video = root.appendingPathComponent("mid-decode.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false)
            let id = try await store.importVideo(from: video)
            let before = try XCTUnwrap(store.project(id: id))
            let original = try Data(contentsOf: source)
            let cancellation = ImportCancellationProbe()
            let parent = Task {
                try await store.importProjectAudio(projectID: id, sourceURL: source, didDecodeFrames: { frames in
                    if frames > 0 { cancellation.progress() }
                })
            }
            cancellation.set { parent.cancel() }
            do {
                _ = try await parent.value
                XCTFail("Expected cancellation after decoded frames were written.")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(cancellation.events, 1, "Parent cancellation must reach the decoding worker.")
            XCTAssertEqual(store.project(id: id), before)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.repository.assetsDirectory(projectID: id).path), [before.recording!.filename])
            XCTAssertNil(store.storageChangeDisabledReason)
        }
    }

    func test_importCleanupFailure_persistsPendingCleanupAndRetriesAfterRestartWithoutReimporting() async throws {
        try await withFixture { _, store, root in
            let job = MediaImportJob(id: UUID(),
                request: MediaImportRequest(kind: .video, path: root.appendingPathComponent("gone.mp4").path, projectID: nil, key: "cleanup"),
                reservedProjectID: UUID(), reservedAssetID: UUID())
            let partial = try store.repository.prepareImportedVideoURL(projectID: job.reservedProjectID, fileExtension: "mp4")
            try Data("partial".utf8).write(to: partial.url)
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            try JSONEncoder().encode([job]).write(to: journal, options: .atomic)
            store.mediaImports = MediaImportController(store: store, beforeCleanup: { _ in throw POSIXError(.EACCES) })
            let failed = try store.mediaImports.get(id: job.id)
            XCTAssertEqual(failed.state, .failed)
            XCTAssertTrue(failed.cleanupPending)
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.url.path))
            let restarted = AppStore(repository: store.repository)
            let recovered = try restarted.mediaImports.get(id: job.id)
            XCTAssertEqual(recovered.state, .failed)
            XCTAssertFalse(recovered.cleanupPending)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.url.path))
            XCTAssertTrue(restarted.projects.isEmpty)
        }
    }

    func test_cancelImport_journalFailureStillSignalsAnotherActiveWorker() async throws {
        try await withFixture { _, store, root in
            var failedWorkerEnded = false
            var blockedWorkerEnded = false
            store.mediaImports = MediaImportController(store: store, beforeCleanup: { job in
                if job.request.key == "failed" { failedWorkerEnded = true }
                if job.request.key == "blocked" { blockedWorkerEnded = true }
            }, beforeImport: { job in
                if job.request.key == "blocked" { try await Task.sleep(for: .seconds(30)) }
            })
            _ = try store.mediaImports.start(kind: .video, path: root.appendingPathComponent("missing.mp4").path, projectID: nil, key: "failed")
            let blocked = try store.mediaImports.start(kind: .video, path: root.appendingPathComponent("other.mp4").path, projectID: nil, key: "blocked")
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            try FileManager.default.removeItem(at: journal)
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            for _ in 0..<100 {
                if failedWorkerEnded { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(failedWorkerEnded)
            XCTAssertThrowsError(try store.mediaImports.cancel(id: blocked.jobID))
            for _ in 0..<100 {
                if blockedWorkerEnded { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let cancellationReachedWorker = blockedWorkerEnded
            try FileManager.default.removeItem(at: journal)
            _ = try store.mediaImports.cancel(id: blocked.jobID)
            for _ in 0..<100 {
                if blockedWorkerEnded { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(cancellationReachedWorker, "Journal failure must not prevent the cancellation signal.")
            XCTAssertEqual(try store.mediaImports.get(id: blocked.jobID).state, .cancelled)
            XCTAssertTrue(store.projects.isEmpty)
        }
    }

    func test_completedAudioCleanup_preservesRegisteredWAVWhileRetryingSnapshotDeletion() async throws {
        try await withFixture { client, store, root in
            let source = root.appendingPathComponent("snapshot.wav")
            try TestVideoFactory.makeToneWAV(at: source, duration: 0.5)
            let video = root.appendingPathComponent("snapshot.mp4")
            _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: false)
            let id = try await store.importVideo(from: video)
            let started: MediaImportStatus = try await call(client, "storybird_import_audio", [
                "path": .string(source.path), "project_id": .string(id.uuidString), "idempotency_key": "snapshot",
            ])
            let done = try await terminal(client, started)
            let asset = try XCTUnwrap(store.project(id: id)?.audioAssets.first)
            let owned = store.repository.assetURL(projectID: id, filename: asset.filename)
            let ownedData = try Data(contentsOf: owned)
            let snapshot = owned.deletingLastPathComponent().appendingPathComponent(".\(asset.filename).source.wav")
            try Data("remaining snapshot".utf8).write(to: snapshot)
            let journal = store.repository.rootURL.appendingPathComponent("media-imports.json")
            var jobs = try JSONDecoder().decode([MediaImportJob].self, from: Data(contentsOf: journal))
            jobs[0].cleanupPending = true
            try JSONEncoder().encode(jobs).write(to: journal, options: .atomic)
            let blocked = AppStore(repository: store.repository)
            blocked.mediaImports = MediaImportController(store: blocked, beforeCleanup: { _ in throw POSIXError(.EACCES) })
            let pending = try blocked.mediaImports.get(id: done.jobID)
            XCTAssertEqual(pending.state, .completed)
            XCTAssertTrue(pending.cleanupPending)
            XCTAssertEqual(try Data(contentsOf: owned), ownedData)
            let reopened = AppStore(repository: store.repository)
            let cleaned = try reopened.mediaImports.get(id: done.jobID)
            XCTAssertEqual(cleaned.state, .completed)
            XCTAssertFalse(cleaned.cleanupPending)
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
            XCTAssertEqual(try Data(contentsOf: owned), ownedData)
        }
    }
}

/// Observes real I/O from detached workers and cancels their parent task. The
/// event count detects missing cancellation forwarding without timing sleeps.
private final class ImportCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var count = 0

    var events: Int { lock.withLock { count } }

    /// Installs the parent task cancellation action before its first actor turn.
    func set(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { self.action = action }
    }

    /// Calls outside the lock so the task cancellation handler can run safely.
    func progress() {
        let cancel = lock.withLock {
            count += 1
            return action
        }
        cancel?()
    }
}
