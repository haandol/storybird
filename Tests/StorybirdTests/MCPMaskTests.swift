import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class MCPMaskTests: XCTestCase {
    private typealias Response = (content: [Tool.Content], isError: Bool?)

    func test_masks_compactCoverEveryLayerAndReorderPreviewApplyUndoExport() async throws {
        try await withClient(cards: true) { client, store, initial, source, root in
            let bytes = try Data(contentsOf: source)
            var project: DemoProject = try decode(await create(client, project: initial, fields: [
                "start_time": 0, "end_time": .double(initial.timelineDuration), "x": 0, "y": 0, "width": 1, "height": 1,
                "timing_mode": "project", "coordinate_space": "canvas", "color_hex": "#FF0000"]))
            let red = try XCTUnwrap(project.effects.last?.id)
            XCTAssertEqual(project.revision, initial.revision + 1)
            for time in [0.5, 2.0] {
                let image = try png(await client.callTool(name: "storybird_render_preview", arguments: ["project_id": .string(project.id.uuidString), "time": .double(time)]))
                for point in [(0.01, 0.01), (0.5, 0.5), (0.98, 0.98)] { try assertColor(image, point: point, channel: 0) }
            }
            project = try decode(await create(client, project: project, fields: [
                "start_time": 0, "end_time": .double(initial.timelineDuration), "x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5,
                "timing_mode": "project", "coordinate_space": "canvas", "color_hex": "#0000FF"]))
            let blue = try XCTUnwrap(project.effects.last?.id)
            try assertColor(try png(await client.callTool(name: "storybird_render_preview", arguments: ["project_id": .string(project.id.uuidString), "time": 2])), point: (0.5, 0.5), channel: 2)
            project = try decode(await client.callTool(name: "storybird_update_effect", arguments: ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "effect_id": .string(red.uuidString), "order_index": 1]))
            XCTAssertEqual(project.effects.filter { !$0.isMask }, initial.effects)
            try assertColor(try png(await client.callTool(name: "storybird_render_preview", arguments: ["project_id": .string(project.id.uuidString), "time": 2])), point: (0.5, 0.5), channel: 0)
            let before = try XCTUnwrap(store.project(id: project.id))
            let args = batch(project, [.object(["target": "effect", "id": .string(red.uuidString), "action": "update", "values": .object(["order_index": 0])])])
            let preview: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_preview_edits", arguments: args))
            XCTAssertEqual(store.project(id: project.id), before)
            let applied: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: args))
            project = applied.project
            XCTAssertEqual(project.effects, preview.project.effects)
            let undo: DemoProject = try decode(await client.callTool(name: "storybird_undo_project", arguments: ["project_id": .string(project.id.uuidString), "expected_revision": .int(project.revision)]))
            XCTAssertEqual(undo.effects, before.effects)
            project = try decode(await client.callTool(name: "storybird_redo_project", arguments: ["project_id": .string(project.id.uuidString), "expected_revision": .int(undo.revision)]))
            let context = try object(await client.callTool(name: "storybird_get_edit_context", arguments: ["project_id": .string(project.id.uuidString)]))
            let targets = try XCTUnwrap(context["targets"] as? [[String: Any]])
            let target = try XCTUnwrap(targets.first { $0["id"] as? String == blue.uuidString })
            XCTAssertEqual((target["values"] as? [String: Any])?["order_index"] as? Int, 1)
            XCTAssertNotNil((target["fields"] as? [String: Any])?["coordinate_space"])
            let export = try await client.callTool(name: "storybird_export_project", arguments: ["project_id": .string(project.id.uuidString), "parent_directory": .string(root.path)])
            XCTAssertNotEqual(export.isError, true, text(export))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: text(export))))
            generator.appliesPreferredTrackTransform = true
            for time in [0.5, 2.0] {
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                try assertColor(frame, point: (0.5, 0.5), channel: 2)
                for point in [(0.01, 0.01), (0.98, 0.98)] { try assertColor(frame, point: point, channel: 0) }
            }
            let removed: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: batch(project,
                [red, blue].map { .object(["target": "effect", "id": .string($0.uuidString), "action": "delete"]) })))
            XCTAssertEqual(removed.project.effects, initial.effects)
            let revealed = try png(await client.callTool(name: "storybird_render_preview", arguments: ["project_id": .string(project.id.uuidString), "time": 0.5]))
            XCTAssertNotEqual(try sample(revealed, point: (0.5, 0.5)), [0, 0, 255])
            let restored: DemoProject = try decode(await client.callTool(name: "storybird_undo_project", arguments: ["project_id": .string(project.id.uuidString), "expected_revision": .int(removed.revision)]))
            XCTAssertEqual(restored.effects, project.effects)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func test_maskSceneEdits_compactFollowOnlyStartAndRejectOverflowOrForgedAnchor() async throws {
        try await withClient { client, store, initial, _, root in
            var project: DemoProject = try decode(await create(client, project: initial, fields: [
                "start_time": 0.5, "end_time": 1.5, "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4,
                "timing_mode": "scene", "coordinate_space": "canvas"]))
            let maskID = project.effects.last!.id
            let moved: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: batch(project,
                [.object(["target": "clip", "id": .string(project.clips[0].id.uuidString), "action": "move", "values": .object(["destination_index": 1])])])) )
            XCTAssertEqual(try mask(moved.project, id: maskID).startTime, 2.5)
            XCTAssertEqual(try mask(moved.project, id: maskID).endTime, 3.5)
            XCTAssertEqual(try mask(moved.project, id: maskID).coordinateSpace, .canvas)
            project = try store.undo(projectID: project.id)
            project = try decode(await client.callTool(name: "storybird_update_effect", arguments: ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "effect_id": .string(maskID.uuidString), "start_time": 3, "end_time": 4,
                "coordinate_space": "content"]))
            let before = try XCTUnwrap(store.project(id: project.id))
            let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let overflow = try await client.callTool(name: "storybird_apply_edits", arguments: batch(project,
                [.object(["target": "clip", "id": .string(project.clips[1].id.uuidString), "action": "update", "values": .object(["playback_rate": 4])])]))
            XCTAssertEqual(overflow.isError, true)
            XCTAssertEqual(store.project(id: project.id), before)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
            var forged = before
            if case var .mask(value) = forged.effects[0] { value.sceneAnchor?.clipID = UUID(); forged.effects[0] = .mask(value) }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let rejected = try await client.callTool(name: "storybird_replace_project", arguments: ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "project_json": .string(String(decoding: try encoder.encode(forged), as: UTF8.self))])
            XCTAssertEqual(rejected.isError, true)
            XCTAssertEqual(store.project(id: project.id), before)
            let deleted: ProjectBatchEditResult = try decode(await client.callTool(name: "storybird_apply_edits", arguments: batch(project,
                [.object(["target": "clip", "id": .string(project.clips[1].id.uuidString), "action": "delete"]) ])))
            XCTAssertFalse(deleted.project.effects.contains { $0.id == maskID })
            XCTAssertEqual(try store.undo(projectID: project.id).effects, before.effects)
        }
    }

    func test_cameraConflict_keepsMasksAndReturnsConflictingIDAndInterval() async throws {
        try await withClient { client, store, initial, _, _ in
            var project: DemoProject = try decode(await create(client, project: initial, fields: [
                "start_time": 0, "end_time": 4, "x": 0, "y": 0, "width": 1, "height": 1,
                "timing_mode": "project", "coordinate_space": "canvas"]))
            project = try decode(await client.callTool(name: "storybird_create_pan_zoom", arguments: ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "start_time": 0, "end_time": 2, "end_x": 0.5, "end_y": 0.5, "end_scale": 2]))
            let camera = try XCTUnwrap(project.effects.last?.id)
            let before = try XCTUnwrap(store.project(id: project.id))
            let conflict = try await client.callTool(name: "storybird_create_pan_zoom", arguments: ["project_id": .string(project.id.uuidString),
                "expected_revision": .int(project.revision), "start_time": 1, "end_time": 3, "end_x": 0.5, "end_y": 0.5, "end_scale": 3])
            XCTAssertEqual(conflict.isError, true)
            XCTAssertTrue(text(conflict).contains(camera.uuidString))
            XCTAssertTrue(text(conflict).contains("1.0...2.0"))
            XCTAssertEqual(store.project(id: project.id), before)
        }
    }

    func test_maskInterval_PNGAndMP4AgreeBeforeAtAndAfterEndpoints() async throws {
        try await withClient { client, _, initial, _, root in
            let project: DemoProject = try decode(await create(client, project: initial, fields: [
                "start_time": 0.2, "end_time": 0.3, "x": 0, "y": 0, "width": 1, "height": 1,
                "timing_mode": "project", "coordinate_space": "canvas", "color_hex": "#FF0000"]))
            let exported = try await client.callTool(name: "storybird_export_project", arguments: ["project_id": .string(project.id.uuidString), "parent_directory": .string(root.path)])
            XCTAssertNotEqual(exported.isError, true, text(exported))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: text(exported))))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (index, active) in [(5, false), (6, true), (9, true), (10, false)] {
                let time = CMTime(value: Int64(index), timescale: 30)
                let frame = try await generator.image(at: time).image
                let preview = try png(await client.callTool(name: "storybird_render_preview", arguments: ["project_id": .string(project.id.uuidString), "time": .double(time.seconds + 0.0001)]))
                for image in [preview, frame] {
                    let pixel = try sample(image, point: (0.5, 0.5))
                    let covered = pixel[0] > 235 && pixel[1] < 20 && pixel[2] < 20
                    XCTAssertEqual(covered, active, "frame \(index): \(pixel)")
                }
            }
        }
    }

    func test_maskFailures_compactLeaveBytesRevisionAndUndoUntouched() async throws {
        try await withClient { client, store, initial, _, root in
            let valid: [String: Value] = ["start_time": 0, "end_time": 1, "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4,
                "timing_mode": "project", "coordinate_space": "canvas"]
            let library = root.appendingPathComponent("library.json"), bytes = try Data(contentsOf: library)
            for (key, value): (String, Value?) in [("timing_mode", nil), ("coordinate_space", nil), ("width", 0),
                ("x", 0.9), ("end_time", 8), ("color_hex", "#FFFFFF00"), ("opacity", 0.5), ("timing_mode", "track"), ("coordinate_space", "screen")] {
                var fields = valid; fields[key] = value
                let result = try await create(client, project: initial, fields: fields)
                XCTAssertEqual(result.isError, true, key)
                XCTAssertEqual(store.project(id: initial.id), initial)
                XCTAssertEqual(try Data(contentsOf: library), bytes)
                XCTAssertThrowsError(try store.undo(projectID: initial.id))
            }
            var stale = initial; stale.revision += 1
            let rejectedStale = try await create(client, project: stale, fields: valid)
            XCTAssertEqual(rejectedStale.isError, true)
            let backup = root.appendingPathComponent("saved-library.json")
            try FileManager.default.moveItem(at: library, to: backup)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
            let failed = try await create(client, project: initial, fields: valid)
            XCTAssertEqual(failed.isError, true)
            XCTAssertEqual(store.project(id: initial.id), initial)
            XCTAssertThrowsError(try store.undo(projectID: initial.id))
            try FileManager.default.removeItem(at: library)
            try FileManager.default.moveItem(at: backup, to: library)
            XCTAssertEqual(try Data(contentsOf: library), bytes)
        }
    }

    private func create(_ client: MCPTestClient, project: DemoProject, fields: [String: Value]) async throws -> Response {
        try await client.callTool(name: "storybird_create_visual_effect", arguments: [
            "project_id": .string(project.id.uuidString), "expected_revision": .int(project.revision),
            "kind": "mask", "input": .object(fields),
        ])
    }
    private func batch(_ project: DemoProject, _ edits: [Value]) -> [String: Value] {
        ["project_id": .string(project.id.uuidString), "expected_revision": .int(project.revision), "edits": .array(edits)]
    }
    private func text(_ response: Response) -> String { response.content.compactMap { if case let .text(text, _, _) = $0 { text } else { nil } }.joined() }
    private func object(_ response: Response) throws -> [String: Any] {
        XCTAssertNotEqual(response.isError, true, text(response))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(response).utf8)) as? [String: Any])
    }
    private func decode<T: Decodable>(_ response: Response) throws -> T {
        XCTAssertNotEqual(response.isError, true, text(response))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text(response).utf8))
    }
    private func mask(_ project: DemoProject, id: UUID) throws -> MaskEffect {
        guard case let .mask(value) = project.effects.first(where: { $0.id == id }) else { throw DemoEffectEditError.effectNotFound }
        return value
    }
    private func png(_ response: Response) throws -> CGImage {
        XCTAssertNotEqual(response.isError, true, text(response))
        let base64 = try XCTUnwrap(response.content.compactMap { if case let .image(value, _, _, _) = $0 { value } else { nil } }.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(XCTUnwrap(Data(base64Encoded: base64)) as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func assertColor(_ image: CGImage, point: (Double, Double), channel: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let rgb = try sample(image, point: point)
        XCTAssertGreaterThan(rgb[channel], 235, "\(rgb)", file: file, line: line)
        for other in 0..<3 where other != channel { XCTAssertLessThan(rgb[other], 20, "\(rgb)", file: file, line: line) }
    }
    private func sample(_ image: CGImage, point: (Double, Double)) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (Int(Double(image.height) * point.1) * image.width + Int(Double(image.width) * point.0)) * 4
        return Array(pixels[index..<(index + 3)])
    }
    private func withClient(cards: Bool = false,
        body: @MainActor (MCPTestClient, AppStore, DemoProject, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-masks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root), id = UUID()
        let target = try repository.prepareVideoRecordingURL(projectID: id)
        let video = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: false, duration: 4, width: 320, height: 180)
        var project = DemoProject(id: id, name: "Mask protocol", recording: VideoRecordingAsset(filename: target.filename, duration: video.duration, width: video.width, height: video.height))
        project.clips = [VideoClip(sourceStart: 0, sourceEnd: 2), VideoClip(sourceStart: 2, sourceEnd: 4)]
        if cards {
            project = try DemoEffectEditor.insertTitle(in: project, after: nil, duration: 1, title: "Private title")
            project = try VideoTimelineEditor.addClickCue(to: project, at: 1.5, x: 0.5, y: 0.5)
            project.clicks[0].caption = "Private description"; project.clicks[0].cueSubtitle.text = "Private Cue"
            project.subtitles = [TimedSubtitle(startTime: 0, endTime: 5, text: "Private caption")]
            project.effects.append(.spotlight(SpotlightEffect(startTime: 1, endTime: 5, x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
            project.effects.append(.panZoom(PanZoomEffect(startTime: 1, endTime: 5, endX: 0.5, endY: 0.5, endScale: 2)))
        }
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let service = StorybirdMCPService(client: StorybirdAppIPCClient(sender: { await host.handle($0) }, launcher: { throw StorybirdControlWireError.invalidMessage }))
        let transport = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transport.server)
        let client = Client(name: "Mask protocol verification", version: "1")
        do {
            _ = try await client.connect(transport: transport.client)
            try await body(MCPTestClient(client: client), store, XCTUnwrap(store.project(id: id)), target.url, root)
            await client.disconnect(); await server.stop()
        } catch { await client.disconnect(); await server.stop(); throw error }
    }
}
