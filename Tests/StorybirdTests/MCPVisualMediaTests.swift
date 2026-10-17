import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MCP
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPVisualMediaTests: XCTestCase {
    private typealias Response = (content: [Tool.Content], isError: Bool?)

    func test_visualMedia_bothProfilesRegisterInspectPlaceUndoCopyAndExportOwnedSources() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile: profile) { client, store, initial, root in
                let video = root.appendingPathComponent("second.mp4")
                _ = try await TestVideoFactory.makeMovie(at: video, includeAudio: true, duration: 2, width: 96, height: 128)
                let picture = root.appendingPathComponent("picture.png")
                try image(at: picture)
                let videoBytes = try Data(contentsOf: video), imageBytes = try Data(contentsOf: picture)
                let v = try await importMedia(client, projectID: initial.id, path: video, key: "video")
                let i = try await importMedia(client, projectID: initial.id, path: picture, key: "image")
                XCTAssertEqual(v.state, .completed); XCTAssertEqual(i.state, .completed)
                let videoID = try XCTUnwrap(v.result?.assetID)
                let imageID = try XCTUnwrap(i.result?.assetID)
                XCTAssertNil(i.result?.duration)
                XCTAssertEqual(i.result?.width, 20)
                XCTAssertEqual(i.result?.height, 40)
                XCTAssertEqual(store.project(id: initial.id)?.revision, initial.revision)
                let listed: [ProjectMediaAsset] = try decode(await client.callTool(name: "storybird_list_media_assets",
                    arguments: ["project_id": .string(initial.id.uuidString)]))
                XCTAssertEqual(Set(listed.map(\.id)), [initial.id, videoID, imageID])
                let raw = try await client.callTool(name: "storybird_render_preview", arguments: [
                    "project_id": .string(initial.id.uuidString), "asset_id": .string(imageID.uuidString), "time": 0,
                ])
                XCTAssertNotEqual(raw.isError, true, text(raw))
                XCTAssertGreaterThan(try redCenter(raw), 220)
                XCTAssertEqual(store.project(id: initial.id)?.revision, initial.revision)

                var project: DemoProject = try decode(await client.callTool(name: "storybird_place_media_asset", arguments: [
                    "project_id": .string(initial.id.uuidString), "expected_revision": .int(initial.revision),
                    "asset_id": .string(videoID.uuidString), "destination_index": 1,
                    "source_start": 1.1, "source_end": 1.6,
                ]))
                XCTAssertEqual(project.clips.last?.mediaAssetID, videoID)
                project = try decode(await client.callTool(name: "storybird_place_media_asset", arguments: [
                    "project_id": .string(initial.id.uuidString), "expected_revision": .int(project.revision),
                    "asset_id": .string(imageID.uuidString), "destination_index": 1, "duration": 0.4,
                ]))
                XCTAssertEqual(project.clips.map(\.kind), [.video, .image, .video])
                XCTAssertEqual(project.timelineDuration, 1.9, accuracy: 0.001)
                let preview = try await client.callTool(name: "storybird_render_preview", arguments: [
                    "project_id": .string(initial.id.uuidString), "time": 1.1,
                ])
                XCTAssertNotEqual(preview.isError, true, text(preview))
                XCTAssertGreaterThan(try redCenter(preview), 220)
                let sound: AudioPreviewResult = try decode(await client.callTool(name: "storybird_render_audio_preview", arguments: [
                    "project_id": .string(initial.id.uuidString), "start_time": 1.45, "duration": 0.2,
                ]))
                defer { try? FileManager.default.removeItem(atPath: sound.path) }
                XCTAssertGreaterThan(sound.peak, 0.05)
                let silence: AudioPreviewResult = try decode(await client.callTool(name: "storybird_render_audio_preview", arguments: [
                    "project_id": .string(initial.id.uuidString), "start_time": 1.05, "duration": 0.2,
                ]))
                defer { try? FileManager.default.removeItem(atPath: silence.path) }
                XCTAssertLessThan(silence.peak, 0.0001)
                _ = try store.undo(projectID: initial.id)
                XCTAssertEqual(store.project(id: initial.id)?.mediaAssets.count, 2)
                XCTAssertEqual(store.project(id: initial.id)?.clips.count, 2)
                project = try store.redo(projectID: initial.id)
                let unused = try await importMedia(client, projectID: initial.id, path: picture, key: "unused")
                XCTAssertEqual(unused.state, .completed)
                let copy: DemoProject = try decode(await client.callTool(name: "storybird_duplicate_project", arguments: [
                    "project_id": .string(initial.id.uuidString), "expected_revision": .int(project.revision),
                ]))
                XCTAssertNotEqual(copy.id, initial.id)
                XCTAssertEqual(copy.revision, 0)
                XCTAssertEqual(Set(copy.mediaAssets.map(\.id)), [videoID, imageID])
                XCTAssertEqual(store.deleteProject(id: initial.id).status, "deleted")
                let copiedPreview = try await client.callTool(name: "storybird_render_preview", arguments: [
                    "project_id": .string(copy.id.uuidString), "time": 1.1,
                ])
                XCTAssertGreaterThan(try redCenter(copiedPreview), 220)
                let exported = try await client.callTool(name: "storybird_export_project", arguments: [
                    "project_id": .string(copy.id.uuidString), "parent_directory": .string(root.path),
                ])
                XCTAssertNotEqual(exported.isError, true, text(exported))
                let movie = AVURLAsset(url: URL(fileURLWithPath: text(exported)))
                let duration = try await movie.load(.duration)
                XCTAssertEqual(duration.seconds, 1.9, accuracy: 1 / 30)
                let audio = try await movie.loadTracks(withMediaType: .audio)
                XCTAssertEqual(audio.count, 1)
                XCTAssertEqual(try Data(contentsOf: video), videoBytes)
                XCTAssertEqual(try Data(contentsOf: picture), imageBytes)
            }
        }
    }

    func test_mediaFailuresAndReplay_preserveRegistryRevisionAndOriginalFiles() async throws {
        try await withClient { client, store, project, root in
            let picture = root.appendingPathComponent("picture.png")
            try image(at: picture)
            let first = try await importMedia(client, projectID: project.id, path: picture, key: "same")
            let replay = try await importMedia(client, projectID: project.id, path: picture, key: "same")
            XCTAssertEqual(first.jobID, replay.jobID)
            XCTAssertEqual(store.project(id: project.id)?.mediaAssets.count, 1)
            let bad = root.appendingPathComponent("corrupt.png")
            try Data("not an image".utf8).write(to: bad)
            let failed = try await importMedia(client, projectID: project.id, path: bad, key: "bad")
            XCTAssertEqual(failed.state, .failed)
            let before = try XCTUnwrap(store.project(id: project.id))
            let id = try XCTUnwrap(first.result?.assetID)
            for extras: [String: Value] in [
                ["asset_id": .string(id.uuidString)],
                ["asset_id": .string(id.uuidString), "duration": 0],
                ["asset_id": .string(id.uuidString), "duration": 1, "expected_revision": 999],
                ["asset_id": .string(UUID().uuidString), "duration": 1],
            ] {
                var args: [String: Value] = ["project_id": .string(project.id.uuidString),
                    "expected_revision": .int(project.revision), "destination_index": 0]
                args.merge(extras) { _, new in new }
                let result = try await client.callTool(name: "storybird_place_media_asset", arguments: args)
                XCTAssertEqual(result.isError, true)
                XCTAssertEqual(store.project(id: project.id), before)
            }
            var forged = before
            forged.name = "Must not save"
            forged.mediaAssets.append(ProjectMediaAsset(kind: .image, filename: "foreign.png", name: "Foreign", width: 1, height: 1))
            XCTAssertThrowsError(try store.saveProject(forged, expectedRevision: before.revision))
            XCTAssertEqual(store.project(id: project.id), before)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
        }
    }

    func test_twentySaveCancelAndRenderFailures_preserveLastLibraryAndOriginalBytes() async throws {
        try await withClient { client, store, initial, root in
            let picture = root.appendingPathComponent("safety.png")
            try image(at: picture)
            let registered = try await importMedia(client, projectID: initial.id, path: picture, key: "safety")
            let imageID = try XCTUnwrap(registered.result?.assetID)
            let before = try XCTUnwrap(store.project(id: initial.id))
            let library = root.appendingPathComponent("library.json")
            let libraryBytes = try Data(contentsOf: library)
            let source = store.repository.assetURL(projectID: before.id, filename: try XCTUnwrap(before.recording?.filename))
            let originalBytes = try Data(contentsOf: source)
            let output = root.appendingPathComponent("existing-output.mp4")
            let sentinel = Data("Existing export must survive".utf8)
            try sentinel.write(to: output)
            let corrupt = root.appendingPathComponent("corrupt.png")
            try Data("corrupt".utf8).write(to: corrupt)
            let cases = ["duplicate ID", "foreign source", "negative source start", "source overflow",
                "rate below minimum", "rate above maximum", "zero image duration", "empty subtitle",
                "subtitle overflow", "invalid canvas", "forged registry", "stale revision",
                "atomic save failure", "cancelled import", "invalid image decode", "overwrite original",
                "missing render source", "empty render timeline", "invalid render audio", "cancelled render"]
            XCTAssertEqual(cases.count, 20)
            for (index, label) in cases.enumerated() {
                var edited = before
                var rejected = false
                do {
                    switch index {
                    case 0: edited.clips.append(edited.clips[0])
                    case 1: edited.clips[0].mediaAssetID = UUID()
                    case 2: edited.clips[0].sourceStart = -0.01
                    case 3: edited.clips[0].sourceEnd = 2
                    case 4: edited.clips[0].playbackRate = 0.24
                    case 5: edited.clips[0].playbackRate = 4.01
                    case 6: edited.clips.append(VideoClip(kind: .image, sourceStart: 0, sourceEnd: 0,
                        freezeDuration: 0, mediaAssetID: imageID))
                    case 7: edited.subtitles.append(TimedSubtitle(startTime: 0, endTime: 0.5, text: ""))
                    case 8: edited.subtitles.append(TimedSubtitle(startTime: 0, endTime: 2, text: "Overflow"))
                    case 9: edited.canvas.backgroundHex = "not RGB"
                    case 10: edited.mediaAssets[0].filename = "foreign.png"
                    case 11:
                        edited.name = "Stale"
                        _ = try store.saveProject(edited, expectedRevision: before.revision + 1)
                    case 12:
                        edited.name = "Unwritten"
                        try await withBlockedLibraryWrite(root: root) {
                            _ = try store.saveProject(edited, expectedRevision: before.revision)
                        }
                    case 13:
                        let task = Task { try await store.importProjectMedia(projectID: before.id, sourceURL: picture) }
                        task.cancel()
                        _ = try await task.value
                    case 14: _ = try await store.importProjectMedia(projectID: before.id, sourceURL: corrupt)
                    case 15:
                        _ = try await LayeredVideoExporter().export(project: before, sourceURL: source, destinationURL: source)
                    case 16:
                        _ = try await LayeredVideoExporter().export(project: before,
                            sourceURL: root.appendingPathComponent("missing.mp4"), destinationURL: output)
                    case 17:
                        edited.clips = []
                        _ = try await LayeredVideoExporter().export(project: edited, sourceURL: source, destinationURL: output)
                    case 18:
                        edited.sourceAudioVolume = -1
                        _ = try await LayeredVideoExporter().export(project: edited, sourceURL: source, destinationURL: output)
                    default:
                        let task = Task { try await LayeredVideoExporter().export(project: before,
                            sourceURL: source, destinationURL: output) }
                        task.cancel()
                        _ = try await task.value
                    }
                    if index < 11 { _ = try store.saveProject(edited, expectedRevision: before.revision) }
                } catch { rejected = true }
                XCTAssertTrue(rejected, label)
                XCTAssertEqual(store.project(id: before.id), before, label)
                XCTAssertEqual(try Data(contentsOf: library), libraryBytes, label)
                XCTAssertEqual(try Data(contentsOf: source), originalBytes, label)
                XCTAssertEqual(try Data(contentsOf: output), sentinel, label)
                XCTAssertThrowsError(try store.undo(projectID: before.id), label)
            }
            XCTAssertEqual(try store.repository.loadProjects().first, before)
        }
    }

    func test_lateMediaRegistration_survivesOlderUndoRedoSnapshotsAndReopen() async throws {
        try await withClient { client, store, initial, root in
            var renamed = initial
            renamed.name = "Edited before import"
            renamed = try store.saveProject(renamed, expectedRevision: initial.revision)
            let picture = root.appendingPathComponent("late.png")
            try image(at: picture)
            let imported = try await importMedia(client, projectID: initial.id, path: picture, key: "late")
            let assetID = try XCTUnwrap(imported.result?.assetID)
            let asset = try XCTUnwrap(store.project(id: initial.id)?.mediaAssets.first)
            let owned = store.repository.assetURL(projectID: initial.id, filename: asset.filename)
            let bytes = try Data(contentsOf: owned)
            XCTAssertEqual(store.project(id: initial.id)?.revision, renamed.revision)
            let undone = try store.undo(projectID: initial.id, expectedRevision: renamed.revision)
            XCTAssertEqual(undone.name, initial.name)
            XCTAssertEqual(undone.mediaAssets, [asset])
            let redone = try store.redo(projectID: initial.id, expectedRevision: undone.revision)
            XCTAssertEqual(redone.name, renamed.name)
            XCTAssertEqual(redone.mediaAssets, [asset])
            XCTAssertEqual(try Data(contentsOf: owned), bytes)
            let reopened = AppStore(repository: store.repository)
            let restored = try XCTUnwrap(reopened.project(id: initial.id))
            XCTAssertEqual(restored.mediaAssets, [asset])
            let placed = try reopened.placeMediaAsset(projectID: initial.id, assetID: assetID,
                expectedRevision: restored.revision, destination: 1, duration: 1)
            XCTAssertEqual(placed.clips.last?.mediaAssetID, assetID)
            XCTAssertEqual(placed.revision, restored.revision + 1)
            XCTAssertEqual(try Data(contentsOf: owned), bytes)
        }
    }

    func test_jpegImport_inspectsOrientedPixelsAndRejectsDisguisedUnsupportedImage() async throws {
        try await withClient { client, store, project, root in
            let png = root.appendingPathComponent("pixels.png")
            try image(at: png)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let jpeg = root.appendingPathComponent("rotated.jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let done = try await importMedia(client, projectID: project.id, path: jpeg, key: "jpeg")
            XCTAssertEqual(done.state, .completed)
            XCTAssertEqual(done.result?.width, 40)
            XCTAssertEqual(done.result?.height, 20)
            let preview = try await client.callTool(name: "storybird_render_preview", arguments: [
                "project_id": .string(project.id.uuidString),
                "asset_id": .string(try XCTUnwrap(done.result?.assetID).uuidString), "time": 0])
            XCTAssertGreaterThan(try redCenter(preview), 220)
            let disguised = root.appendingPathComponent("unsupported.png")
            let gif = try XCTUnwrap(CGImageDestinationCreateWithURL(disguised as CFURL, "com.compuserve.gif" as CFString, 1, nil))
            CGImageDestinationAddImage(gif, pixels, nil)
            XCTAssertTrue(CGImageDestinationFinalize(gif))
            let failed = try await importMedia(client, projectID: project.id, path: disguised, key: "gif")
            XCTAssertEqual(failed.state, .failed)
            XCTAssertEqual(store.project(id: project.id)?.mediaAssets.count, 1)
            XCTAssertEqual(store.project(id: project.id)?.revision, project.revision)
        }
    }

    func test_mediaSaveFailure_keepsRegistryAssetsAndUndoForRetry() async throws {
        try await withClient { client, store, project, root in
            let picture = root.appendingPathComponent("source.png")
            try image(at: picture)
            let sourceBytes = try Data(contentsOf: picture)
            let directory = store.repository.assetsDirectory(projectID: project.id)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let initialLibrary = try Data(contentsOf: root.appendingPathComponent("library.json"))
            try await withBlockedLibraryWrite(root: root) {
                let failed = try await importMedia(client, projectID: project.id, path: picture, key: "save-failed")
                XCTAssertEqual(failed.state, .failed)
                XCTAssertNil(failed.result)
                XCTAssertEqual(store.project(id: project.id), project)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), files)
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), initialLibrary)
            let ready = try await importMedia(client, projectID: project.id, path: picture, key: "retry")
            let assetID = try XCTUnwrap(ready.result?.assetID)
            let before = try XCTUnwrap(store.project(id: project.id))
            let registeredLibrary = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let arguments: [String: Value] = ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "asset_id": .string(assetID.uuidString),
                "destination_index": 1, "duration": 1]
            try await withBlockedLibraryWrite(root: root) {
                let result = try await client.callTool(name: "storybird_place_media_asset", arguments: arguments)
                XCTAssertEqual(result.isError, true)
                XCTAssertEqual(store.project(id: project.id), before)
                XCTAssertThrowsError(try store.undo(projectID: project.id))
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), registeredLibrary)
            let placed: DemoProject = try decode(await client.callTool(name: "storybird_place_media_asset", arguments: arguments))
            XCTAssertEqual(placed.revision, project.revision + 1)
            _ = try store.undo(projectID: project.id)
            XCTAssertEqual(store.project(id: project.id)?.clips, before.clips)
            XCTAssertEqual(store.project(id: project.id)?.mediaAssets, before.mediaAssets)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
            XCTAssertEqual(try Data(contentsOf: picture), sourceBytes)
        }
    }

    /// A directory forces Foundation's actual atomic replacement to fail. The
    /// last good library is restored before subsequent retry/reopen assertions.
    private func withBlockedLibraryWrite(root: URL, body: () async throws -> Void) async throws {
        let library = root.appendingPathComponent("library.json")
        let backup = root.appendingPathComponent("library-test-backup.json")
        try FileManager.default.moveItem(at: library, to: backup)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.moveItem(at: backup, to: library)
        }
        try await body()
    }

    func test_mediaRestart_recoversCommittedAssetAndCleansAbandonedCopyWithoutReimporting() async throws {
        try await withClient { _, store, project, root in
            let picture = root.appendingPathComponent("source.png")
            try image(at: picture)
            let id = UUID()
            let asset = try await store.importProjectMedia(projectID: project.id, sourceURL: picture, assetID: id)
            let committed = MediaImportJob(id: UUID(),
                request: MediaImportRequest(kind: .media, path: picture.path, projectID: project.id, key: "committed"),
                reservedProjectID: project.id, reservedAssetID: id)
            let abandoned = MediaImportJob(id: UUID(),
                request: MediaImportRequest(kind: .media, path: picture.path, projectID: project.id, key: "abandoned"),
                reservedProjectID: project.id, reservedAssetID: UUID())
            let partial = store.repository.assetURL(projectID: project.id,
                filename: ProjectMediaFiles.filename(assetID: abandoned.reservedAssetID, fileExtension: "png"))
            try Data("partial".utf8).write(to: partial)
            try JSONEncoder().encode([committed, abandoned]).write(to: root.appendingPathComponent("media-imports.json"))
            try FileManager.default.removeItem(at: picture)
            let reopened = AppStore(repository: store.repository)
            let recovered = try reopened.mediaImports.get(id: committed.id)
            XCTAssertEqual(recovered.state, .completed)
            XCTAssertEqual(recovered.result?.assetID, asset.id)
            XCTAssertEqual(try reopened.mediaImports.get(id: abandoned.id).state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(reopened.project(id: project.id)?.mediaAssets, [asset])
            XCTAssertEqual(reopened.project(id: project.id)?.revision, project.revision)
        }
    }

    func test_mediaCancellation_isTerminalWithoutRegisteringAsset() async throws {
        try await withClient { client, store, project, root in
            let picture = root.appendingPathComponent("cancel.png")
            try image(at: picture)
            store.mediaImports = MediaImportController(store: store, beforeImport: { _ in
                try await Task.sleep(for: .seconds(10))
            })
            let begun: MediaImportStatus = try decode(await client.callTool(name: "storybird_import_media", arguments: [
                "project_id": .string(project.id.uuidString), "path": .string(picture.path), "idempotency_key": "cancel",
            ]))
            _ = try await client.callTool(name: "storybird_cancel_import", arguments: ["job_id": .string(begun.jobID.uuidString)])
            var state = begun
            for _ in 0..<200 {
                state = try decode(await client.callTool(name: "storybird_get_import", arguments: ["job_id": .string(begun.jobID.uuidString)]))
                if state.state != .importing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(state.state, .cancelled)
            XCTAssertNil(state.result)
            XCTAssertEqual(store.project(id: project.id)?.mediaAssets, [])
            XCTAssertEqual(store.project(id: project.id)?.revision, project.revision)
            XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
        }
    }

    func test_nativeMediaPanel_importAndPlaceUseAppOwnedRegistryAndRevision() async throws {
        try await withClient { _, store, project, root in
            let source = root.appendingPathComponent("native-second.mp4")
            _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false, duration: 0.5, width: 128, height: 72)
            var placed: UUID?
            let panel = TimelineMediaPanel(store: store, projectID: project.id, playhead: 1,
                onPlaced: { placed = $0 }, chooseFile: { source })
                .frame(width: 340, height: 520)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
            let view = NSHostingView(rootView: panel)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 340, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            click(window, x: 297, y: 495)
            for _ in 0..<200 {
                if store.project(id: project.id)?.mediaAssets.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.project(id: project.id)?.mediaAssets.count, 1)
            XCTAssertEqual(store.project(id: project.id)?.revision, project.revision)
            try await Task.sleep(for: .milliseconds(350))
            click(window, x: 297, y: 371)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNotNil(placed)
            XCTAssertEqual(store.project(id: project.id)?.clips.count, 2)
            XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/media-panel-ui")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("native-media.png"))
        }
    }

    private func click(_ window: NSWindow, x: Double, y: Double) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        }
    }

    private func importMedia(_ client: Client, projectID: UUID, path: URL, key: String) async throws -> MediaImportStatus {
        var result: MediaImportStatus = try decode(await client.callTool(name: "storybird_import_media", arguments: [
            "project_id": .string(projectID.uuidString), "path": .string(path.path), "idempotency_key": .string(key),
        ]))
        for _ in 0..<500 {
            if result.state != .importing { return result }
            try await Task.sleep(for: .milliseconds(10))
            result = try decode(await client.callTool(name: "storybird_get_import", arguments: ["job_id": .string(result.jobID.uuidString)]))
        }
        XCTFail("Import never reached a terminal state")
        return result
    }

    private func text(_ result: Response) -> String {
        result.content.compactMap { if case let .text(value, _, _) = $0 { return value }; return nil }.joined()
    }
    private func decode<T: Decodable>(_ result: Response) throws -> T {
        XCTAssertNotEqual(result.isError, true, text(result))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text(result).utf8))
    }
    private func redCenter(_ result: Response) throws -> UInt8 {
        let payload = try XCTUnwrap(result.content.compactMap { item -> String? in
            if case let .image(base64, _, _, _) = item { return base64 }; return nil
        }.first)
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel[(image.height / 2 * image.width + image.width / 2) * 4]
    }
    private func image(at url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 40, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        try ProjectMediaFiles.png(XCTUnwrap(context.makeImage())).write(to: url)
    }

    private func withClient(profile: StorybirdMCPToolProfile = .legacy,
                            _ body: @MainActor (Client, AppStore, DemoProject, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visual-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let target = try repository.prepareVideoRecordingURL(projectID: id)
        let video = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: false, duration: 1, width: 128, height: 72)
        var project = DemoProject(id: id, name: "Primary", recording: VideoRecordingAsset(filename: target.filename,
            duration: video.duration, width: video.width, height: video.height, hasAudio: false))
        project.theme.showsBranding = false
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let service = StorybirdMCPService(client: StorybirdAppIPCClient(sender: { await host.handle($0) },
            launcher: { throw StorybirdControlWireError.invalidMessage }), toolProfile: profile)
        let transport = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transport.server)
        let client = Client(name: "Visual media protocol", version: "1")
        do {
            _ = try await client.connect(transport: transport.client)
            try await body(client, store, XCTUnwrap(store.project(id: id)), root)
            await client.disconnect(); await server.stop()
        } catch {
            await client.disconnect(); await server.stop()
            throw error
        }
    }
}
