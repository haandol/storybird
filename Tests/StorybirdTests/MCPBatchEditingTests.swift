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

    func test_targetedClipDuplicate_compactReturnOwnedLayerIDsAndRejectInvalidOrStaleEdits() async throws {
        try await withClient { raw, store, original, root in
            let client = raw
            let input: [String: Value] = ["project_id": .string(original.id.uuidString),
                "expected_revision": .int(original.revision), "clip_id": .string(original.clips[0].id.uuidString), "destination_index": 1]
            let result: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_duplicate_clip", arguments: input))
            XCTAssertEqual(result.revision, original.revision + 1)
            XCTAssertEqual(result.project.clips.map(\.sourceStart), [0, 0, 2, 4])
            XCTAssertEqual(result.project.subtitles.count, original.subtitles.count + 1)
            XCTAssertEqual(Set(result.created.flatMap(\.created).map(\.target)), [.clip, .subtitle])
            XCTAssertFalse(result.idsProvisional)
            let storedResult = try XCTUnwrap(store.project(id: original.id))
            XCTAssertEqual(storedResult.clips, result.project.clips)
            let disk = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let stale = try await client.callTool(name: "storybird_duplicate_clip", arguments: input)
            XCTAssertEqual(stale.isError, true)
            let failure = try object(stale)
            XCTAssertEqual(failure["current_revision"] as? Int, result.revision)
            XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "revision_conflict")
            var valid = input; valid["expected_revision"] = .int(result.revision)
            for patch: [String: Value] in [["destination_index": -1], ["destination_index": 99], ["destination_index": true],
                ["clip_id": .string(UUID().uuidString)], ["duration": 2]] {
                let rejected = try await client.callTool(name: "storybird_duplicate_clip", arguments: valid.merging(patch) { _, new in new })
                XCTAssertEqual(rejected.isError, true)
                XCTAssertEqual(store.project(id: original.id), storedResult)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), disk)
            }
            let undone: DemoProject = try decode(await client.callTool(name: "storybird_undo_project", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(result.revision)]))
            XCTAssertEqual(undone.clips, original.clips)
            XCTAssertEqual(undone.subtitles, original.subtitles)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
        }
    }

    func test_targetedHeldDurationAndMediaPlacement_compactShareValidationNoopAndUndo() async throws {
        try await withClient { raw, store, original, root in
            let client = raw
            let picture = root.appendingPathComponent("held.png")
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            try ProjectMediaFiles.png(XCTUnwrap(context.makeImage())).write(to: picture)
            let asset = try await store.importProjectMedia(projectID: original.id, sourceURL: picture)
            let placed: DemoProject = try decode(await client.callTool(name: "storybird_place_media_asset", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(original.revision),
                "asset_id": .string(asset.id.uuidString), "destination_index": 1, "duration": 1]))
            XCTAssertEqual(placed.clips[1].kind, .image)
            XCTAssertEqual(placed.clips[1].mediaAssetID, asset.id)
            XCTAssertEqual(placed.revision, original.revision + 1)
            _ = try store.saveProject(VideoTimelineEditor.insertFreeze(project: placed,
                after: placed.clips.last!.id, sourceTime: 5, duration: 1), expectedRevision: placed.revision)
            for kind in [VideoClipKind.image, .freeze] {
                let before = try XCTUnwrap(store.project(id: original.id))
                let clip = try XCTUnwrap(before.clips.first { $0.kind == kind })
                let input: [String: Value] = ["project_id": .string(original.id.uuidString),
                    "expected_revision": .int(before.revision), "clip_id": .string(clip.id.uuidString), "duration": 1.5]
                let changed: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_set_clip_duration", arguments: input))
                XCTAssertEqual(changed.revision, before.revision + 1)
                XCTAssertEqual(changed.project.clips.first { $0.id == clip.id }?.outputDuration, 1.5)
                XCTAssertEqual(changed.project.clips.first { $0.id == clip.id }?.mediaAssetID, clip.mediaAssetID)
                var fresh = input; fresh["expected_revision"] = .int(changed.revision)
                let noop: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_set_clip_duration", arguments: fresh))
                XCTAssertEqual(noop.revision, changed.revision)
                XCTAssertFalse(noop.wouldChange)
                let storedResult = try XCTUnwrap(store.project(id: original.id))
                XCTAssertEqual(storedResult.clips, changed.project.clips)
                let disk = try Data(contentsOf: root.appendingPathComponent("library.json"))
                for patch: [String: Value] in [["duration": 0], ["duration": true], ["duration": "2"],
                    ["clip_id": .string(original.clips[0].id.uuidString)], ["unexpected": 1], ["expected_revision": .int(before.revision)]] {
                    let rejected = try await client.callTool(name: "storybird_set_clip_duration", arguments: fresh.merging(patch) { _, new in new })
                    XCTAssertEqual(rejected.isError, true)
                    XCTAssertEqual(store.project(id: original.id), storedResult)
                    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), disk)
                }
                let undone: DemoProject = try decode(await client.callTool(name: "storybird_undo_project", arguments: [
                    "project_id": .string(original.id.uuidString), "expected_revision": .int(changed.revision)]))
                XCTAssertEqual(undone.clips, before.clips)
                XCTAssertEqual(undone.subtitles, before.subtitles)
            }
            // The established shared placement name remains callable on compact.
            let beforeShared = try XCTUnwrap(store.project(id: original.id))
            let shared: DemoProject = try decode(await raw.callTool(name: "storybird_place_media_asset", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(beforeShared.revision),
                "asset_id": .string(asset.id.uuidString), "destination_index": 0, "duration": 0.5]))
            XCTAssertEqual(shared.clips[0].mediaAssetID, asset.id)
            XCTAssertEqual(shared.revision, beforeShared.revision + 1)
            XCTAssertEqual(try store.undo(projectID: original.id).clips, beforeShared.clips)
            XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
        }
    }

    func test_targetedClipSaveFailure_compactPreserveSceneAndHistory() async throws {
        try await withClient { raw, store, original, root in
            let client = raw
            let library = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("backup.json")
            let bytes = try Data(contentsOf: library)
            try FileManager.default.moveItem(at: library, to: backup)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            defer {
                try? FileManager.default.removeItem(at: library)
                try? FileManager.default.moveItem(at: backup, to: library)
            }
            let rejected = try await client.callTool(name: "storybird_duplicate_clip", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(original.revision),
                "clip_id": .string(original.clips[0].id.uuidString), "destination_index": 1])
            XCTAssertEqual(rejected.isError, true)
            XCTAssertEqual(try object(rejected)["current_revision"] as? Int, original.revision)
            XCTAssertEqual(store.project(id: original.id), original)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
        }
    }

    func test_captionFilesAndSplitMerge_compactPreserveOriginalsAndExplicitText() async throws {
        try await withClient { client, store, original, root in
            let source = root.appendingPathComponent("captions.srt")
            let bytes = Data("1\n00:00:00,000 --> 00:00:00,500\n가족 👨‍👩‍👧‍👦 안녕\n\n2\n00:00:05,000 --> 00:00:05,500\nSecond caption\n".utf8)
            try bytes.write(to: source)
            let imported: SubtitleImportResult = try decode(await client.callTool(name: "storybird_import_subtitles", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(original.revision), "path": .string(source.path)]))
            XCTAssertEqual(imported.revision, original.revision + 1)
            XCTAssertEqual(imported.added_ids.count, 2)
            XCTAssertEqual(Array(imported.project.subtitles.prefix(2)), original.subtitles)
            let captionID = imported.added_ids[0]
            let split: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: args(imported.project,
                [edit(.subtitle, captionID, "split", ["time": 0.25, "text_offset": 3])])) )
            let rightID = try XCTUnwrap(split.created.flatMap(\.created).first { $0.target == .subtitle }?.id)
            XCTAssertEqual(split.project.subtitles.first { $0.id == captionID }?.text, "가족 ")
            XCTAssertEqual(split.project.subtitles.first { $0.id == rightID }?.text, "👨‍👩‍👧‍👦 안녕")
            let merge: Value = .object(["target": "subtitle", "id": .string(captionID.uuidString), "action": "merge",
                "related_ids": .array([.string(rightID.uuidString)]), "values": .object(["text": "사용자가 지정한 문구"])])
            let preview: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_preview_edits", arguments: args(split.project, [merge])))
            XCTAssertEqual(store.project(id: original.id)?.subtitles, split.project.subtitles)
            let merged: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: args(split.project, [merge])))
            XCTAssertEqual(merged.project.subtitles, preview.project.subtitles)
            XCTAssertEqual(merged.project.subtitles.first { $0.id == captionID }?.text, "사용자가 지정한 문구")
            XCTAssertEqual(merged.project.subtitles.first { $0.id == captionID }?.endTime, 0.5)
            let library = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let outputArgs: [String: Value] = ["project_id": .string(original.id.uuidString), "scope": "independent", "parent_directory": .string(root.path)]
            let a: SubtitleExportResult = try decode(await client.callTool(name: "storybird_export_subtitles", arguments: outputArgs))
            let b: SubtitleExportResult = try decode(await client.callTool(name: "storybird_export_subtitles", arguments: outputArgs))
            XCTAssertNotEqual(a.path, b.path)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: a.path)), try Data(contentsOf: URL(fileURLWithPath: b.path)))
            XCTAssertEqual(a.caption_count, merged.project.subtitles.count)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), library)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try store.undo(projectID: original.id).subtitles, split.project.subtitles)
        }
    }

    func test_srtInvalidImportAndExport_preserveProjectFilesAndHistory() async throws {
        try await withClient { client, store, original, root in
            let source = root.appendingPathComponent("invalid.srt")
            try Data("1\n00:00:00,000 --> 00:00:01,000\nValid first\n\n2\n00:00:05,000 --> 00:00:09,000\nInvalid last\n".utf8).write(to: source)
            let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let rejected = try await client.callTool(name: "storybird_import_subtitles", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(original.revision), "path": .string(source.path)])
            XCTAssertEqual(rejected.isError, true)
            XCTAssertEqual(try object(rejected)["current_revision"] as? Int, original.revision)
            XCTAssertEqual(store.project(id: original.id), original)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
            let missingScope = try await client.callTool(name: "storybird_export_subtitles", arguments: ["project_id": .string(original.id.uuidString)])
            XCTAssertEqual(missingScope.isError, true)
            var tiny = original
            tiny.subtitles = [TimedSubtitle(startTime: 0.0001, endTime: 0.0004, text: "Collapsed")]
            tiny = try store.saveProject(tiny, expectedRevision: original.revision)
            let files = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            let collapsed = try await client.callTool(name: "storybird_export_subtitles", arguments: [
                "project_id": .string(original.id.uuidString), "scope": "independent", "parent_directory": .string(root.path)])
            XCTAssertEqual(collapsed.isError, true)
            XCTAssertEqual((try object(collapsed)["error"] as? [String: Any])?["code"] as? String, "invalid_srt_output")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), files)
            XCTAssertEqual(store.project(id: original.id), tiny)
        }
    }

    func test_subtitleMerge_rejectsDuplicateRelatedTargetsAndCueConversionAtomically() async throws {
        try await withClient { client, store, original, _ in
            let id = original.subtitles[0].id
            let merge: Value = .object(["target": "subtitle", "id": .string(id.uuidString), "action": "merge",
                "related_ids": .array([.string(original.subtitles[1].id.uuidString)]), "values": .object(["text": "Combined"])])
            let result = try await client.callTool(name: "storybird_apply_edits", arguments: args(original, [merge,
                edit(.subtitle, original.subtitles[1].id, "update", ["text": "Duplicate explicit target"])]))
            XCTAssertEqual(result.isError, true)
            XCTAssertEqual((try object(result)["error"] as? [String: Any])?["code"] as? String, "duplicate_target")
            XCTAssertEqual(store.project(id: original.id), original)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
        }
    }

    func test_captionAndCanvasFailures_returnExactTargetWithoutPartialSave() async throws {
        try await withClient { client, store, project, root in
            let missing = UUID()
            let merge: Value = .object(["target": "subtitle", "id": .string(project.subtitles[0].id.uuidString), "action": "merge",
                "related_ids": .array([.string(missing.uuidString)]), "values": .object(["text": "Cannot merge"])])
            let invalid = try await client.callTool(name: "storybird_apply_edits", arguments: args(project, [merge]))
            XCTAssertEqual(invalid.isError, true)
            let error = try XCTUnwrap(object(invalid)["error"] as? [String: Any])
            XCTAssertEqual(error["target_id"] as? String, missing.uuidString)
            XCTAssertEqual(error["property"] as? String, "related_ids")
            let context = try object(await client.callTool(name: "storybird_get_edit_context", arguments: ["project_id": .string(project.id.uuidString)]))
            let captions = try XCTUnwrap(context["captions"] as? [[String: Any]])
            XCTAssertEqual(captions.count, project.subtitles.count + project.clicks.count)
            XCTAssertEqual(captions.compactMap { $0["text"] as? String }.sorted(), project.subtitles.map(\.text).sorted())
            let library = root.appendingPathComponent("library.json")
            let bytes = try Data(contentsOf: library)
            for updates in [
                [edit(.project, project.id, "update", ["canvas_preset": "portrait"]), edit(.clip, project.clips[0].id, "update", ["anchor_x": 1.01])],
                [edit(.project, project.id, "update", ["canvas_preset": "cinema"])],
                [edit(.project, project.id, "update", ["canvas_background_hex": "transparent"])],
                [edit(.clip, project.clips[0].id, "update", ["fit_mode": "stretch"])],
                [edit(.subtitle, project.subtitles[0].id, "split", ["time": 1, "text_offset": 1.5])]
            ] {
                let result = try await client.callTool(name: "storybird_apply_edits", arguments: args(project, updates))
                XCTAssertEqual(result.isError, true)
                XCTAssertEqual(store.project(id: project.id), project)
                XCTAssertEqual(try Data(contentsOf: library), bytes)
                XCTAssertThrowsError(try store.undo(projectID: project.id))
            }
            let source = root.appendingPathComponent("stale.srt")
            try Data("1\n00:00:00,000 --> 00:00:00,500\nImported\n".utf8).write(to: source)
            var request: [String: Value] = ["project_id": .string(project.id.uuidString), "expected_revision": .int(project.revision + 1), "path": .string(source.path)]
            let stale = try await client.callTool(name: "storybird_import_subtitles", arguments: request)
            XCTAssertEqual(stale.isError, true)
            XCTAssertEqual(try object(stale)["current_revision"] as? Int, project.revision)
            request["expected_revision"] = .int(project.revision)
            let backup = root.appendingPathComponent("backup.json")
            try FileManager.default.moveItem(at: library, to: backup)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            let failed = try await client.callTool(name: "storybird_import_subtitles", arguments: request)
            XCTAssertEqual(failed.isError, true)
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
            try FileManager.default.removeItem(at: library)
            try FileManager.default.moveItem(at: backup, to: library)
            XCTAssertEqual(try Data(contentsOf: library), bytes)
        }
    }

    func test_heldClipSplit_compactPreserveImageFreezeSourcesAndUndo() async throws {
        try await withClient { client, store, original, root in
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

    func test_batchBothProfiles_previewAndApplyShareTimingAndCommitOneUndo() async throws {
        try await withClient { client, store, original, root in
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
            let undone: DemoProject = try decode(await client.callTool(name: "storybird_edit_history", arguments: [
                "project_id": .string(original.id.uuidString), "expected_revision": .int(applied.revision),
                "action": "undo", "input": .object([:])]))
            XCTAssertEqual(undone.clips, original.clips)
            XCTAssertEqual(undone.subtitles, original.subtitles)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
        }
    }

    func test_batchInvalidTargetsFieldsAndDerivedTiming_preserveEveryByteAndHistory() async throws {
        try await withClient { client, store, original, root in
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
        try await withClient { client, store, original, _ in
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
        try await withClient { client, store, original, root in
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
    private func withClient(body: @MainActor (MCPTestClient, AppStore, DemoProject, URL) async throws -> Void) async throws {
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
            launcher: { throw StorybirdControlWireError.invalidMessage }))
        let transports = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transports.server)
        let client = Client(name: "Batch protocol", version: "1")
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(MCPTestClient(client: client), store, XCTUnwrap(store.project(id: id)), root)
            await client.disconnect(); await server.stop()
        } catch {
            await client.disconnect(); await server.stop()
            throw error
        }
    }
}
