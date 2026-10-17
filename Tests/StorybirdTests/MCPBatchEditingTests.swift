import AppKit
import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPBatchEditingTests: XCTestCase {
    private typealias Response = (content: [Tool.Content], isError: Bool?)

    func test_heldClipSplit_bothProfilesPreserveImageFreezeSourcesAndUndo() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile) { client, store, original, root in
                let picture = root.appendingPathComponent("still.png")
                let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                    bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                try ProjectMediaFiles.png(XCTUnwrap(context.makeImage())).write(to: picture)
                let asset = try await store.importProjectMedia(projectID: original.id, sourceURL: picture)
                var current = try store.placeMediaAsset(projectID: original.id, assetID: asset.id,
                    expectedRevision: original.revision, destination: 1, duration: 1)
                current = try store.saveProject(VideoTimelineEditor.insertFreeze(project: current,
                    after: current.clips.last!.id, sourceTime: 5, duration: 1), expectedRevision: current.revision)
                for kind in [VideoClipKind.image, .freeze] {
                    current = try XCTUnwrap(store.project(id: original.id))
                    let clip = try XCTUnwrap(current.clips.first { $0.kind == kind })
                    let beforeIDs = Set(current.clips.map(\.id))
                    let input = args(current, [edit(.clip, clip.id, "split", ["clip_offset": 0.4])])
                    let preview: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_preview_edits", arguments: input))
                    XCTAssertEqual(store.project(id: original.id), current)
                    let applied: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: input))
                    let children = applied.project.clips.filter { !beforeIDs.contains($0.id) }
                    XCTAssertEqual(children.map(\.kind), [kind, kind])
                    XCTAssertEqual(children.map(\.outputDuration), [0.4, 0.6])
                    XCTAssertTrue(children.allSatisfy { $0.mediaAssetID == clip.mediaAssetID && $0.sourceStart == clip.sourceStart })
                    XCTAssertEqual(applied.timelineDuration, preview.timelineDuration)
                    XCTAssertEqual(applied.revision, current.revision + 1)
                    XCTAssertEqual(try store.undo(projectID: original.id).clips, current.clips)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
            }
        }
    }

    func test_batchBothProfiles_previewAndApplyShareTimingAndCommitOneUndo() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            try await withClient(profile) { client, store, original, root in
                let context = try object(await client.callTool(name: "storybird_get_edit_context", arguments: [
                    "project_id": .string(original.id.uuidString), "playhead": 1]))
                let targets = try XCTUnwrap(context["targets"] as? [[String: Any]])
                let clipTarget = try XCTUnwrap(targets.first { $0["id"] as? String == original.clips[0].id.uuidString })
                let fields = try XCTUnwrap(clipTarget["fields"] as? [String: [String: Any]])
                XCTAssertEqual(fields["source_end"]?["maximum"] as? Double, 6)
                XCTAssertTrue((context["alignment_candidates"] as? [[String: Any]])?.contains { $0["kind"] as? String == "playhead" } == true)
                let edits: [Value] = [
                    edit(.clip, original.clips[0].id, "move", ["destination_index": 2]),
                    edit(.subtitle, original.subtitles[0].id, "update", ["font_size": 22]),
                ]
                let arguments = args(original, edits)
                let library = root.appendingPathComponent("library.json")
                let bytes = try Data(contentsOf: library)
                let preview: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_preview_edits", arguments: arguments))
                XCTAssertEqual(preview.status, "previewed")
                XCTAssertTrue(preview.idsProvisional)
                XCTAssertEqual(preview.project.subtitles[0].startTime, 4.5)
                XCTAssertEqual(preview.project.subtitles[0].endTime, 5.5)
                XCTAssertEqual(preview.project.subtitles[0].style.fontSize, 22)
                XCTAssertEqual(preview.project.subtitles[1], original.subtitles[1])
                XCTAssertEqual(store.project(id: original.id), original)
                XCTAssertEqual(try Data(contentsOf: library), bytes)
                XCTAssertThrowsError(try store.undo(projectID: original.id))
                let applied: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: arguments))
                XCTAssertEqual(applied.status, "applied")
                XCTAssertFalse(applied.idsProvisional)
                XCTAssertEqual(applied.revision, original.revision + 1)
                XCTAssertEqual(applied.project.clips, preview.project.clips)
                XCTAssertEqual(applied.project.subtitles, preview.project.subtitles)
                XCTAssertTrue(applied.directChanges.contains(ProjectEditReference(target: .clip, id: original.clips[0].id)))
                XCTAssertTrue(applied.derivedChanges.contains(ProjectEditReference(target: .clip, id: original.clips[1].id)))
                let undone: DemoProject
                if profile == .legacy {
                    undone = try decode(await client.callTool(name: "storybird_undo_project", arguments: [
                        "project_id": .string(original.id.uuidString), "expected_revision": .int(applied.revision)]))
                } else {
                    undone = try decode(await client.callTool(name: "storybird_edit_history", arguments: [
                        "project_id": .string(original.id.uuidString), "expected_revision": .int(applied.revision),
                        "action": "undo", "input": .object([:])]))
                }
                XCTAssertEqual(undone.clips, original.clips)
                XCTAssertEqual(undone.subtitles, original.subtitles)
                XCTAssertThrowsError(try store.undo(projectID: original.id))
            }
        }
    }

    func test_batchInvalidTargetsFieldsAndDerivedTiming_preserveEveryByteAndHistory() async throws {
        try await withClient(.legacy) { client, store, original, root in
            let first = original.subtitles[0].id
            let second = original.subtitles[1].id
            let library = root.appendingPathComponent("library.json")
            let bytes = try Data(contentsOf: library)
            let cases: [([Value], String, UUID)] = [
                ([edit(.project, original.id, "delete", [:])], "unsupported_action", original.id),
                ([edit(.subtitle, first, "update", ["text": "Must not persist"]),
                  edit(.subtitle, second, "update", ["font_size": true])], "invalid_value", second),
                ([edit(.subtitle, first, "update", ["text": "Must not persist", "font_szie": 12])], "unknown_property", first),
                ([edit(.subtitle, first, "update", ["text": "First"]), edit(.subtitle, first, "delete", [:])], "duplicate_target", first),
                ([edit(.clip, original.clips[0].id, "move", ["destination_index": 2]),
                  edit(.subtitle, first, "update", ["start_time": 2])], "conflicting_timing", first),
                ([edit(.subtitle, first, "update", ["text": "Must not persist"]),
                  edit(.subtitle, second, "update", ["end_time": 99])], "invalid_timeline", second),
            ]
            for (edits, code, target) in cases {
                for name in ["storybird_preview_edits", "storybird_apply_edits"] {
                    let response = try await client.callTool(name: name, arguments: args(original, edits))
                    XCTAssertEqual(response.isError, true)
                    let result = try object(response)
                    XCTAssertEqual(result["current_revision"] as? Int, original.revision)
                    let failure = try XCTUnwrap(result["error"] as? [String: Any])
                    XCTAssertEqual(failure["code"] as? String, code)
                    XCTAssertEqual(failure["target_id"] as? String, target.uuidString)
                    XCTAssertNotNil(failure["property"])
                    XCTAssertEqual(store.project(id: original.id), original)
                    XCTAssertEqual(try Data(contentsOf: library), bytes)
                    XCTAssertThrowsError(try store.undo(projectID: original.id))
                }
            }
            var badEnvelope = args(original, [edit(.subtitle, first, "update", ["text": "No"] )])
            badEnvelope["typo"] = true
            let response = try object(await client.callTool(name: "storybird_apply_edits", arguments: badEnvelope))
            XCTAssertEqual(response["current_revision"] as? Int, original.revision)
            XCTAssertEqual((response["error"] as? [String: Any])?["property"] as? String, "typo")
        }
    }

    func test_batchSplit_returnsFinalNewIDsAndRejectsStaleFollowup() async throws {
        try await withClient(.compact) { client, store, original, _ in
            let edits = [edit(.clip, original.clips[0].id, "split", ["source_time": 1])]
            let preview: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_preview_edits", arguments: args(original, edits)))
            let applied: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: args(original, edits)))
            let previewIDs = Set(preview.created.flatMap(\.created).map(\.id))
            let actual = applied.created.flatMap(\.created).filter { $0.target == .clip }
            XCTAssertEqual(actual.count, 2)
            XCTAssertTrue(Set(actual.map(\.id)).isDisjoint(with: previewIDs))
            XCTAssertEqual(applied.project.clips.map(\.sourceStart), preview.project.clips.map(\.sourceStart))
            let newClip = try XCTUnwrap(applied.project.clips.first { actual.map(\.id).contains($0.id) })
            let followup = [edit(.clip, newClip.id, "update", ["playback_rate": 0.5])]
            let stale = try object(await client.callTool(name: "storybird_apply_edits", arguments: args(original, followup)))
            XCTAssertEqual(stale["current_revision"] as? Int, applied.revision)
            XCTAssertEqual((stale["error"] as? [String: Any])?["code"] as? String, "revision_conflict")
            XCTAssertEqual(store.project(id: original.id)?.clips, applied.project.clips)
            let saved: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: args(applied.project, followup)))
            XCTAssertEqual(saved.revision, applied.revision + 1)
            XCTAssertEqual(saved.project.clips.first { $0.id == newClip.id }?.playbackRate, 0.5)
        }
    }

    func test_batchSaveFailure_andNoopPreserveUndoAndOriginalIndex() async throws {
        try await withClient(.legacy) { client, store, original, root in
            let noop: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments:
                args(original, [edit(.subtitle, original.subtitles[0].id, "update", ["text": .string(original.subtitles[0].text)])])))
            XCTAssertEqual(noop.revision, original.revision)
            XCTAssertFalse(noop.wouldChange)
            XCTAssertTrue(noop.directChanges.isEmpty)
            let library = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("backup.json")
            let bytes = try Data(contentsOf: library)
            try FileManager.default.moveItem(at: library, to: backup)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: library)
                try? FileManager.default.moveItem(at: backup, to: library)
            }
            let result = try await client.callTool(name: "storybird_apply_edits", arguments: args(original, [
                edit(.subtitle, original.subtitles[0].id, "update", ["text": "Unwritten"]),
                edit(.subtitle, original.subtitles[1].id, "update", ["text": "Also unwritten"])]))
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual(store.project(id: original.id), original)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
        }
    }

    private func edit(_ kind: ProjectEditTarget, _ id: UUID, _ action: String, _ values: [String: Value]) -> Value {
        .object(["target": .string(kind.rawValue), "id": .string(id.uuidString), "action": .string(action), "values": .object(values)])
    }
    private func args(_ project: DemoProject, _ edits: [Value]) -> [String: Value] {
        ["project_id": .string(project.id.uuidString), "expected_revision": .int(project.revision), "edits": .array(edits)]
    }
    private func text(_ result: Response) -> String {
        result.content.compactMap { if case let .text(text, _, _) = $0 { text } else { nil } }.joined()
    }
    private func object(_ result: Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }
    private func decode<T: Decodable>(_ result: Response) throws -> T {
        XCTAssertNotEqual(result.isError, true, text(result))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text(result).utf8))
    }
    private func withClient(_ profile: StorybirdMCPToolProfile,
        body: @MainActor (Client, AppStore, DemoProject, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let source = try repository.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: source.url, includeAudio: false, duration: 6)
        var project = DemoProject(id: id, name: "Batch", recording: VideoRecordingAsset(filename: source.filename,
            duration: media.duration, width: media.width, height: media.height))
        project.clips = [VideoClip(sourceStart: 0, sourceEnd: 2), VideoClip(sourceStart: 2, sourceEnd: 4), VideoClip(sourceStart: 4, sourceEnd: 6)]
        project.subtitles = [TimedSubtitle(startTime: 0.5, endTime: 1.5, text: "Scene linked",
            sceneAnchor: try SceneTiming.anchor(at: 0.5, in: project)), TimedSubtitle(startTime: 3.5, endTime: 4.5, text: "Fixed")]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let service = StorybirdMCPService(client: StorybirdAppIPCClient(sender: { await host.handle($0) },
            launcher: { throw StorybirdControlWireError.invalidMessage }), toolProfile: profile)
        let transports = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transports.server)
        let client = Client(name: "Batch protocol", version: "1")
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client, store, XCTUnwrap(store.project(id: id)), root)
            await client.disconnect(); await server.stop()
        } catch {
            await client.disconnect(); await server.stop()
            throw error
        }
    }
}
