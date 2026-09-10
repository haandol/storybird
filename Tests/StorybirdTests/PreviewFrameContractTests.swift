@preconcurrency import AVFoundation
import AppKit
import CoreImage
import ImageIO
import MCP
import StorybirdCore
import SwiftUI
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

/// Synthetic media only. Pixel checks decode the PNG/MP4, independently of
/// VideoOverlayPresentation's visibility predicates.
@MainActor
final class PreviewFrameContractTests: XCTestCase {
    func test_hostSubframe_returnsSelectedFrameTimePixelsAndLayerIDs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, initial, source) = try await fixture(root: root, fps: 30)
        var project = initial
        project.subtitles = [subtitle(start: 0.407, end: 0.6)]
        project = try VideoTimelineEditor.addClickCue(to: project, at: 1.2, x: 0.2, y: 0.2)
        project = try store.saveProject(project, expectedRevision: initial.revision)
        let before = try snapshot(store, source: source)
        let response = await preview(StorybirdExternalControlHost(store: store), project, time: "0.413")
        XCTAssertFalse(response.isError, response.text)
        let metadata = try metadata(response)
        let time = try XCTUnwrap(metadata["time"] as? Double)
        XCTAssertEqual(time, 0.4, accuracy: 0.00001)
        XCTAssertEqual(metadata["visible_layer_ids"] as? [String], [])
        XCTAssertEqual(metadata["incomplete_click_ids"] as? [String], project.clicks.map { $0.id.uuidString })
        let image = try png(response)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
        XCTAssertFalse(try hasRedOverlay(image))
        XCTAssertEqual(try frameMarker(image), 12, accuracy: 1)
        XCTAssertEqual(try snapshot(store, source: source), before)
    }

    func test_hostPreview_successRangeNonfiniteAndSourceFailures_preserveStateAndUndo() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, source) = try await fixture(root: root, fps: 60)
        var changed = original
        changed.name = "One real edit"
        let project = try store.saveProject(changed, expectedRevision: original.revision)
        let host = StorybirdExternalControlHost(store: store)
        let before = try snapshot(store, source: source)
        for time in ["0", "0.413", "1.999"] {
            let result = await preview(host, project, time: time)
            XCTAssertFalse(result.isError, result.text)
            XCTAssertNotNil(result.imageData)
            XCTAssertEqual(try snapshot(store, source: source), before)
        }
        // JSON has no NaN/Infinity literals: exercise the real parser with
        // overflowing JSON numbers, invalid literals, strings, null and boolean.
        for time in ["-0.001", "2", "2.01", "1e999", "-1e999", "NaN", "Infinity", "\"NaN\"", "null", "true"] {
            let result = await preview(host, project, time: time)
            XCTAssertTrue(result.isError, "Unexpected success for \(time)")
            XCTAssertNil(result.imageData, time)
            XCTAssertEqual(try snapshot(store, source: source), before)
        }
        let sourceBytes = try Data(contentsOf: source)
        try Data("unreadable synthetic source".utf8).write(to: source)
        let corruptBefore = try snapshot(store, source: source)
        let failed = await preview(host, project, time: "0.4")
        XCTAssertTrue(failed.isError)
        XCTAssertNil(failed.imageData)
        XCTAssertEqual(try snapshot(store, source: source), corruptBefore)
        try sourceBytes.write(to: source)
        // Observe the actual history, rather than only checking revision.
        let undone = try store.undo(projectID: project.id)
        var expectedUndo = original
        expectedUndo.revision = undone.revision
        expectedUndo.updatedAt = undone.updatedAt
        XCTAssertEqual(undone, expectedUndo)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        let redone = try store.redo(projectID: project.id)
        var expectedRedo = project
        expectedRedo.revision = redone.revision
        expectedRedo.updatedAt = redone.updatedAt
        XCTAssertEqual(redone, expectedRedo)
        XCTAssertThrowsError(try store.redo(projectID: project.id))
    }

    func test_renderedOverlayBoundaries_pngAndMP4WithinOneSourceFrame() async throws {
        for fps in [30, 60, 120] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (store, initial, source) = try await fixture(root: root, fps: fps)
            var project = initial
            // At 120fps this pulse fits entirely between old 30Hz output frames.
            let start = (floor(0.2 * Double(fps)) + 0.25) / Double(fps)
            let end = start + 1 / Double(fps)
            project.subtitles = [subtitle(start: start, end: end)]
            try store.repository.saveProjects([project])
            let playback = try await readyPlayback(source: source, project: project)
            XCTAssertLessThanOrEqual(playback.frameDuration.seconds, 1 / Double(fps))
            XCTAssertEqual(playback.frameDuration, CMTime(value: 1, timescale: Int32(fps)))
            let exporter = LayeredVideoExporter()
            let output = try await exporter.export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("export.mp4"))
            let frames = try await decodedFrames(output)
            let active = try frames.filter { try hasRedOverlay($0.image) }
            XCTAssertFalse(active.isEmpty, "\(fps)fps pulse was dropped")
            var pngActive: [Double] = []
            for index in 4...(fps / 3) {
                let time = Double(index) / Double(fps)
                let data = try await exporter.previewPNG(project: project, sourceURL: source, projectTime: time)
                if try hasRedOverlay(decodePNG(data)) { pngActive.append(time) }
            }
            let pngStart = try XCTUnwrap(pngActive.first)
            let pngEnd = try XCTUnwrap(pngActive.last) + 1 / Double(fps)
            let exportStart = try XCTUnwrap(active.first?.time)
            let last = try XCTUnwrap(active.last?.time)
            let exportEnd = try XCTUnwrap(frames.first(where: { $0.time > last + 0.000001 })?.time)
            XCTAssertLessThanOrEqual(abs(pngStart - exportStart), 1 / Double(fps) + 0.00001)
            XCTAssertLessThanOrEqual(abs(pngEnd - exportEnd), 1 / Double(fps) + 0.00001)
            XCTAssertLessThanOrEqual(try XCTUnwrap(frames.dropFirst().first?.time), 1 / Double(fps) + 0.00001)
            print("BOUNDARY fps=\(fps) png=[\(pngStart),\(pngEnd)) mp4=[\(exportStart),\(exportEnd)) frames=\(frames.count)")
        }
    }

    func test_editedSchedule_mapsActualSourceIntoOwningClipIncludingSpeedFreezeAndOffset() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, initial, source) = try await fixture(root: root, fps: 60, mediaStart: 1)
        var edited = initial
        edited.clips = [
            VideoClip(sourceStart: 1, sourceEnd: 1.5, playbackRate: 2),
            VideoClip(kind: .freeze, sourceStart: 1.2, sourceEnd: 1.2, freezeDuration: 0.2),
            VideoClip(sourceStart: 0.3, sourceEnd: 0.8, playbackRate: 0.5),
            VideoClip(sourceStart: 1, sourceEnd: 1.5),
        ]
        edited.subtitles = [subtitle(start: 0.11, end: 0.42)]
        let project = try store.saveProject(edited, expectedRevision: initial.revision)
        let before = try snapshot(store, source: source)
        let host = StorybirdExternalControlHost(store: store)
        // Expected indices come from the writer's timestamps, not production mapping.
        let cases: [(request: Double, actual: Double, index: Int)] = [
            (0, 0, 60), (0.113, 13.0 / 120, 73), (0.249, 29.0 / 120, 89),
            (0.25, 0.25, 72), (0.413, 49.0 / 120, 72), (0.45, 0.45, 18),
            (0.471, 56.0 / 120, 18), (0.55, 0.55, 21), (1.45, 1.45, 60),
            (1.949, 233.0 / 120, 89),
        ]
        for value in cases {
            let response = await preview(host, project, time: String(value.request))
            XCTAssertFalse(response.isError, "\(value.request): \(response.text)")
            let metadata = try metadata(response)
            XCTAssertEqual(try XCTUnwrap(metadata["time"] as? Double), value.actual, accuracy: 0.00001)
            let visible = value.actual >= 0.11 && value.actual <= 0.42
            XCTAssertEqual(metadata["visible_layer_ids"] as? [String],
                visible ? project.subtitles.map { $0.id.uuidString } : [])
            let image = try png(response)
            XCTAssertEqual(try frameMarker(image), Double(value.index), accuracy: 1)
            XCTAssertEqual(try hasRedOverlay(image), visible)
            XCTAssertEqual(try snapshot(store, source: source), before)
            print("EDITED request=\(value.request) actual=\(metadata["time"]!) sourceIndex=\(try frameMarker(image))")
        }
    }

    func test_nonFrameAlignedTrimAndTrailingCard_keepOwnerAndLastSourceFrame() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, initial, source) = try await fixture(root: root, fps: 60)
        var project = initial
        project.clips = [VideoClip(sourceStart: 0.307, sourceEnd: 0.807)]
        project.effects = [.cta(CTACardEffect(startTime: 0.5, endTime: 0.7, title: "End", buttonLabel: "Done"))]
        let exporter = LayeredVideoExporter()
        let first = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 0)
        XCTAssertEqual(first.projectTime, 0)
        XCTAssertEqual(try frameMarker(decodePNG(first.pngData)), 18)
        let card = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 0.699)
        XCTAssertEqual(card.projectTime, 41.0 / 60, accuracy: 0.00001)
        // Make the card transparent to expose the held final source frame.
        if case var .cta(value) = project.effects[0] {
            value.style.backgroundOpacity = 0
            project.effects[0] = .cta(value)
        }
        let transparent = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 0.699)
        XCTAssertEqual(try frameMarker(decodePNG(transparent.pngData)), 119)
        for invalid in [Double.nan, .infinity, -.infinity] {
            do {
                _ = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: invalid)
                XCTFail("Nonfinite renderer request succeeded")
            } catch {}
        }
    }

    func test_vfrRenderedBoundaries_useShortestSourceFrameRatherThanAverageRate() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Alternates 120fps and 30fps intervals: average 48fps is not the bound.
        let ticks = stride(from: 0, to: 240, by: 5).flatMap { [$0, $0 + 1] }
        let times = ticks.map { Double($0) / 120 }
        let (_, initial, source) = try await fixture(root: root, fps: 120, times: times)
        var project = initial
        project.subtitles = [subtitle(start: 25.0 / 120, end: 25.5 / 120)]
        let exporter = LayeredVideoExporter()
        let output = try await exporter.export(project: project, sourceURL: source,
            destinationURL: root.appendingPathComponent("vfr-export.mp4"))
        let frames = try await decodedFrames(output)
        let active = try frames.filter { try hasRedOverlay($0.image) }
        let start = try XCTUnwrap(active.first?.time)
        let end = try XCTUnwrap(frames.first(where: { $0.time > active.last!.time + 0.000001 })?.time)
        let on = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 25.1 / 120)
        let off = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 26.1 / 120)
        XCTAssertTrue(try hasRedOverlay(decodePNG(on.pngData)))
        XCTAssertFalse(try hasRedOverlay(decodePNG(off.pngData)))
        XCTAssertLessThanOrEqual(abs(on.projectTime - start), 1.0 / 120 + 0.00001)
        XCTAssertLessThanOrEqual(abs(off.projectTime - end), 1.0 / 120 + 0.00001)
        XCTAssertLessThanOrEqual(try XCTUnwrap(frames.dropFirst().first?.time), 1.0 / 120 + 0.00001)
        print("VFR sourceFrames=\(times.count) minimum=0.008333333 png=[\(on.projectTime),\(off.projectTime)) mp4=[\(start),\(end)) outputFrames=\(frames.count)")
    }

    func test_fractional5994Cadence_preservesRationalFrameTimeAndPixels() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let step = 1001.0 / 60000
        let times = (0..<120).map { Double($0) * step }
        let (_, initial, source) = try await fixture(root: root, fps: 60, times: times, duration: 120 * step)
        var project = initial
        project.subtitles = [subtitle(start: 13.25 * step, end: 14.25 * step)]
        let exporter = LayeredVideoExporter()
        let output = try await exporter.export(project: project, sourceURL: source,
            destinationURL: root.appendingPathComponent("fractional.mp4"))
        let frames = try await decodedFrames(output)
        XCTAssertEqual(frames.count, 120)
        let active = try frames.filter { try hasRedOverlay($0.image) }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(try XCTUnwrap(active.first?.time), 14 * step, accuracy: 0.000001)
        for index in [0, 13, 14, 15, 119] {
            let frame = try await exporter.previewFrame(project: project, sourceURL: source,
                projectTime: (Double(index) + 0.4) * step)
            XCTAssertEqual(frame.projectTime, Double(index) * step, accuracy: 0.000001)
            XCTAssertEqual(try frameMarker(decodePNG(frame.pngData)), Double(index))
            XCTAssertEqual(try hasRedOverlay(decodePNG(frame.pngData)), index == 14)
        }
        print("FRACTIONAL cadence=1001/60000 frames=120 overlayPNG/MP4=[\(14 * step),\(15 * step))")
    }

    func test_productionMCPClient_previewReturnsActualMetadataAndPNG() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, project, source) = try await fixture(root: root, fps: 60)
        let host = StorybirdExternalControlHost(store: store)
        let ipc = StorybirdAppIPCClient(sender: { request in await host.handle(request) },
            launcher: { throw LayeredVideoExportError.cannotReadVideo })
        let server = await StorybirdMCPService(client: ipc).makeServer()
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        let client = Client(name: "Preview frame contract", version: "1")
        do {
            _ = try await client.connect(transport: pair.client)
            let before = try snapshot(store, source: source)
            let result = try await client.callTool(name: "storybird_render_preview",
                arguments: ["project_id": .string(project.id.uuidString), "time": .double(0.413)])
            XCTAssertNotEqual(result.isError, true)
            var sawText = false
            var sawImage = false
            for content in result.content {
                switch content {
                case let .text(text, _, _):
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                    XCTAssertEqual(try XCTUnwrap(object["time"] as? Double), 0.4, accuracy: 0.00001)
                    sawText = true
                case let .image(data, mimeType, _, _):
                    XCTAssertEqual(mimeType, "image/png")
                    let image = try decodePNG(XCTUnwrap(Data(base64Encoded: data)))
                    XCTAssertEqual(image.width, 320)
                    XCTAssertEqual(image.height, 180)
                    XCTAssertEqual(try frameMarker(image), 24, accuracy: 1)
                    sawImage = true
                default: XCTFail("Unexpected preview content")
                }
            }
            XCTAssertTrue(sawText && sawImage)
            let invalid = try await client.callTool(name: "storybird_render_preview",
                arguments: ["project_id": .string(project.id.uuidString), "time": .double(2)])
            XCTAssertEqual(invalid.isError, true)
            XCTAssertEqual(try snapshot(store, source: source), before)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    func test_editedRenderedBoundaries_speedAndFreezePreserveOneSourceFrameBound() async throws {
        for rate in [0.25, 0.5, 2.0, 4.0] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (_, initial, source) = try await fixture(root: root, fps: 60)
            var project = initial
            project.clips = [
                VideoClip(sourceStart: 0.5, sourceEnd: 1, playbackRate: rate),
                VideoClip(kind: .freeze, sourceStart: 1, sourceEnd: 1, freezeDuration: 0.3),
            ]
            let freezeStart = 0.5 / rate
            project.subtitles = [
                subtitle(start: 0.037, end: 0.071),
                subtitle(start: freezeStart + 0.037, end: freezeStart + 0.071),
            ]
            let playback = try await readyPlayback(source: source, project: project)
            XCTAssertLessThanOrEqual(playback.frameDuration.seconds, 1.0 / 60)
            XCTAssertEqual(playback.frameDuration,
                CMTime(value: 1, timescale: Int32(60 * max(1, rate))))
            let exporter = LayeredVideoExporter()
            let output = try await exporter.export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("edited-export.mp4"))
            let frames = try await decodedFrames(output)
            for layer in project.subtitles {
                let candidates = try frames.filter {
                    guard $0.time >= layer.startTime - 1.0 / 60,
                          $0.time <= layer.endTime + 1.0 / 60 else { return false }
                    return try hasRedOverlay($0.image)
                }
                let exportStart = try XCTUnwrap(candidates.first?.time, "rate=\(rate), start=\(layer.startTime)")
                let last = try XCTUnwrap(candidates.last?.time)
                let exportEnd = try XCTUnwrap(frames.first(where: { $0.time > last + 0.000001 })?.time)
                var on: [Double] = []
                var off: [Double] = []
                for time in stride(from: max(0, layer.startTime - 0.02), through: layer.endTime + 0.09, by: 1.0 / 240) {
                    let frame = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: time)
                    if try hasRedOverlay(decodePNG(frame.pngData)) { on.append(frame.projectTime) }
                    else if !on.isEmpty { off.append(frame.projectTime) }
                }
                let pngStart = try XCTUnwrap(on.first, "rate=\(rate) preview omitted pulse")
                let pngEnd = try XCTUnwrap(off.first)
                XCTAssertLessThanOrEqual(abs(pngStart - exportStart), 1.0 / 60 + 0.00001)
                XCTAssertLessThanOrEqual(abs(pngEnd - exportEnd), 1.0 / 60 + 0.00001)
                print("EDITED_BOUNDARY rate=\(rate) segment=\(layer.startTime < freezeStart ? "video" : "freeze") png=[\(pngStart),\(pngEnd)) mp4=[\(exportStart),\(exportEnd))")
            }
        }
    }

    func test_compositionGenerator_heldFrameReturnsProjectTimeRatherThanSourceTime() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, initial, source) = try await fixture(root: root, fps: 60)
        var project = initial
        project.clips = [VideoClip(sourceStart: 0.5, sourceEnd: 1, playbackRate: 0.25)]
        let sourceAsset = AVURLAsset(url: source)
        let tracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let timeline = try VideoTimelineCompositionBuilder.build(project: project, sourceTrack: XCTUnwrap(tracks.first))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: timeline.duration)
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: timeline.track)]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: 320, height: 180)
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        let generator = AVAssetImageGenerator(asset: timeline.asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [0.037, 0.05, 0.07, 0.083333333, 0.12] {
            let requested = CMTime(seconds: time, preferredTimescale: 60000)
            let result = try await generator.image(at: requested)
            XCTAssertEqual(result.actualTime, requested)
            XCTAssertEqual(try frameMarker(result.image), time < 1.0 / 15 ? 30 : 31)
            print("PROBE request=\(time) actual=\(result.actualTime.seconds) marker=\(try frameMarker(result.image))")
        }
    }

    func test_clickComponentsAndIndependentSubtitle_renderSameOnOffFramesInPNGAndMP4() async throws {
        for fps in [30, 60, 120] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (_, initial, source) = try await fixture(root: root, fps: fps)
            let start = (floor(0.2 * Double(fps)) + 0.25) / Double(fps)
            let end = start + 2 / Double(fps)
            var project = try VideoTimelineEditor.addClickCue(to: initial, at: (start + end) / 2, x: 0.85, y: 0.5)
            project.clicks[0].indicator.startTime = start
            project.clicks[0].indicator.endTime = end
            project.clicks[0].indicator.colorHex = "#00FF00"
            project.clicks[0].description.startTime = start
            project.clicks[0].description.endTime = end
            project.clicks[0].description.text = "D"
            project.clicks[0].description.style.backgroundHex = "#FF0000"
            project.clicks[0].description.style.backgroundOpacity = 1
            project.clicks[0].description.position = .custom
            project.clicks[0].description.x = 0.2
            project.clicks[0].description.y = 0.5
            project.clicks[0].cueSubtitle.startTime = start
            project.clicks[0].cueSubtitle.endTime = end
            project.clicks[0].cueSubtitle.text = "CUE"
            project.clicks[0].cueSubtitle.position = .top
            project.clicks[0].cueSubtitle.style.backgroundHex = "#FFFF00"
            project.clicks[0].cueSubtitle.style.backgroundOpacity = 1
            var independent = subtitle(start: start, end: end)
            independent.style.backgroundHex = "#FF00FF"
            project.subtitles = [independent]
            let exporter = LayeredVideoExporter()
            let output = try await exporter.export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("components.mp4"))
            let frames = try await decodedFrames(output)
            var activeCount = 0
            for frame in frames where frame.time >= start - 2 / Double(fps) && frame.time <= end + 2 / Double(fps) {
                let preview = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: frame.time)
                let pngColors = try overlayColors(decodePNG(preview.pngData))
                let mp4Colors = try overlayColors(frame.image)
                let active = frame.time >= start && frame.time <= end
                XCTAssertEqual(pngColors, [Bool](repeating: active, count: 4), "PNG \(fps)fps @\(frame.time)")
                XCTAssertEqual(mp4Colors, pngColors, "MP4 \(fps)fps @\(frame.time)")
                if active { activeCount += 1 }
            }
            XCTAssertEqual(activeCount, 2)
            print("COMPONENTS fps=\(fps) ring+description+cueSubtitle+independentSubtitle=2 active frames; PNG/MP4 pixel agreement")
        }
    }

    func test_oversizedAutomaticCaption_pngAndMP4FitPaddingAtAllCorners() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, initial, source) = try await fixture(root: root, fps: 30, height: 76)
        let frame = CGRect(x: 0, y: 0, width: 320, height: 76)
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let safeFrame = frame.insetBy(dx: metrics.edgeInset - 1, dy: metrics.edgeInset - 1)
        for (index, point) in [(0.02, 0.02), (0.98, 0.02), (0.02, 0.98), (0.98, 0.98)].enumerated() {
            var project = try VideoTimelineEditor.addClickCue(to: initial, at: 0.5, x: point.0, y: point.1)
            project.clicks[0].indicator.opacity = 0
            project.clicks[0].description.text = "A large automatic caption with several lines"
            project.clicks[0].description.style.fontSize = 96
            project.clicks[0].description.style.backgroundHex = "#FF0000"
            project.clicks[0].description.style.backgroundOpacity = 1
            project.clicks[0].cueSubtitle.text = "Cue"
            let exporter = LayeredVideoExporter()
            let preview = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: 0.5)
            let previewBounds = try redBounds(decodePNG(preview.pngData))
            XCTAssertTrue(safeFrame.contains(previewBounds), "PNG \(point): \(previewBounds)")
            XCTAssertEqual(previewBounds.height, 64, accuracy: 2, "Fit includes original vertical padding.")
            let output = try await exporter.export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("caption-\(index).mp4"))
            let frames = try await decodedFrames(output)
            let image = try XCTUnwrap(frames.first(where: { abs($0.time - 0.5) < 0.000001 })?.image)
            let exportedBounds = try redBounds(image)
            XCTAssertTrue(safeFrame.contains(exportedBounds), "MP4 \(point): \(exportedBounds)")
            XCTAssertEqual(exportedBounds.minX, previewBounds.minX, accuracy: 1)
            XCTAssertEqual(exportedBounds.minY, previewBounds.minY, accuracy: 1)
            XCTAssertEqual(exportedBounds.height, previewBounds.height, accuracy: 2)
            print("CAPTION corner=\(point) PNG=\(previewBounds) MP4=\(exportedBounds) safe=\(safeFrame)")
        }
    }

    func test_exactInclusiveEndpoints_hostPNGAndMP4AgreeBeforeAtAndAfterBoundary() async throws {
        for fps in [30, 60, 120] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (store, initial, source) = try await fixture(root: root, fps: fps)
            var edited = initial
            edited.subtitles = [subtitle(start: 6 / Double(fps), end: 8 / Double(fps))]
            let project = try store.saveProject(edited, expectedRevision: initial.revision)
            let host = StorybirdExternalControlHost(store: store)
            let output = try await LayeredVideoExporter().export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("endpoints.mp4"))
            let frames = try await decodedFrames(output)
            for (tick, active) in [(5.999, false), (6.0, true), (8.0, true), (8.25, true), (9.0, false)] {
                let response = await preview(host, project, time: String(tick / Double(fps)))
                XCTAssertFalse(response.isError, response.text)
                let object = try metadata(response)
                let actualTime = try XCTUnwrap(object["time"] as? Double)
                XCTAssertEqual(actualTime, floor(tick) / Double(fps), accuracy: 0.000001)
                XCTAssertEqual(object["visible_layer_ids"] as? [String],
                    active ? [project.subtitles[0].id.uuidString] : [])
                XCTAssertEqual(try hasRedOverlay(png(response)), active, "PNG \(fps)fps tick \(tick)")
                let exported = try XCTUnwrap(frames.last(where: { $0.time <= actualTime + 0.000001 }))
                XCTAssertEqual(try hasRedOverlay(exported.image), active, "MP4 \(fps)fps tick \(tick)")
            }
            print("ENDPOINTS fps=\(fps) before-start=off start=on end=on next-frame=off; host/PNG/MP4 agree")
        }
    }

    func test_nativeUIRenderedBoundaries_matchPNGAndMP4At30_60_120fps() async throws {
        guard ProcessInfo.processInfo.environment["STORYBIRD_RUN_PREVIEW_FRAME_UI"] == "1" else {
            throw XCTSkip("Run alone with STORYBIRD_RUN_PREVIEW_FRAME_UI=1 after the native performance slot.")
        }
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/timeline-preview-review/ui-boundaries")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for fps in [30, 60, 120] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (_, initial, source) = try await fixture(root: root, fps: fps)
            var project = initial
            let start = (floor(0.2 * Double(fps)) + 0.25) / Double(fps)
            project.subtitles = [subtitle(start: start, end: start + 1 / Double(fps))]
            let exporter = LayeredVideoExporter()
            let exportedURL = try await exporter.export(project: project, sourceURL: source,
                destinationURL: root.appendingPathComponent("native-comparison.mp4"))
            let exported = try await decodedFrames(exportedURL)
            let playback = try await readyPlayback(source: source, project: project)
            XCTAssertEqual(playback.frameDuration, CMTime(value: 1, timescale: Int32(fps)))
            let hosted = NSHostingView(rootView: NativeFrameOverlayProbe(project: project, playback: playback))
            hosted.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 320, height: 180),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosted
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            let activeTick = Int(ceil(start * Double(fps)))
            for (offset, label) in [(-1, "before"), (0, "on"), (1, "after")] {
                let time = Double(activeTick + offset) / Double(fps)
                let expected = offset == 0
                playback.seek(to: time)
                var bitmap: NSBitmapImageRep?
                var matched = false
                for _ in 0..<50 {
                    hosted.layoutSubtreeIfNeeded()
                    let current = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
                    hosted.cacheDisplay(in: hosted.bounds, to: current)
                    let image = try XCTUnwrap(current.cgImage)
                    bitmap = current
                    if abs(playback.currentTime - time) < 0.000001,
                       try hasRedOverlay(image) == expected {
                        matched = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(matched, "Actual UI failed \(fps)fps \(label) @\(time)")
                let captured = try XCTUnwrap(bitmap)
                let image = try XCTUnwrap(captured.cgImage)
                XCTAssertEqual(try hasRedOverlay(image), expected)
                // A nonempty blue canvas proves off-state checks are not empty captures.
                let bytes = try pixels(image)
                XCTAssertGreaterThan(stride(from: 0, to: bytes.count, by: 4).filter {
                    bytes[$0 + 2] > 150 && bytes[$0] < 80 && bytes[$0 + 1] < 80
                }.count, 1_000)
                try XCTUnwrap(captured.representation(using: .png, properties: [:]))
                    .write(to: artifacts.appendingPathComponent("ui-\(fps)-\(label).png"))
                let png = try await exporter.previewFrame(project: project, sourceURL: source, projectTime: time)
                XCTAssertEqual(png.projectTime, time, accuracy: 0.000001)
                XCTAssertEqual(try hasRedOverlay(decodePNG(png.pngData)), expected)
                let video = try XCTUnwrap(exported.first(where: { abs($0.time - time) < 0.000001 }))
                XCTAssertEqual(try hasRedOverlay(video.image), expected)
                print("NATIVE_BOUNDARY fps=\(fps) phase=\(label) projectTime=\(time) nativeTime=\(playback.currentTime) red=\(expected) UI/PNG/MP4 agree")
            }
        }
    }

    private func readyPlayback(source: URL, project: DemoProject) async throws -> VideoPlaybackModel {
        let model = VideoPlaybackModel(url: source, project: project)
        for _ in 0..<400 {
            if model.player.currentItem != nil { return model }
            if model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(model.errorMessage ?? "Native playback composition did not become ready")
        throw LayeredVideoExportError.cannotReadVideo
    }

    private struct Snapshot: Equatable {
        let projects: [DemoProject]
        let library: Data
        let source: Data
    }

    private func snapshot(_ store: AppStore, source: URL) throws -> Snapshot {
        Snapshot(projects: store.projects,
            library: try Data(contentsOf: store.repository.rootURL.appendingPathComponent("library.json")),
            source: try Data(contentsOf: source))
    }

    private func preview(_ host: StorybirdExternalControlHost, _ project: DemoProject, time: String) async -> StorybirdControlResponse {
        await host.handle(StorybirdControlRequest(name: "storybird_render_preview",
            argumentsJSON: Data("{\"project_id\":\"\(project.id.uuidString)\",\"time\":\(time)}".utf8)))
    }

    private func metadata(_ response: StorybirdControlResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])
    }

    private func png(_ response: StorybirdControlResponse) throws -> CGImage {
        try decodePNG(XCTUnwrap(response.imageData))
    }

    private func decodePNG(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func subtitle(start: Double, end: Double) -> TimedSubtitle {
        TimedSubtitle(startTime: start, endTime: end, text: "FRAME", position: .bottom,
            style: TextOverlayStyle(backgroundHex: "#FF0000", backgroundOpacity: 1))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width,
                height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func hasRedOverlay(_ image: CGImage) throws -> Bool {
        let bytes = try pixels(image)
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] > 180 && bytes[index + 1] < 80 && bytes[index + 2] < 80 { count += 1 }
        }
        return count > 100
    }

    private func overlayColors(_ image: CGImage) throws -> [Bool] {
        let bytes = try pixels(image)
        var counts = [Int](repeating: 0, count: 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = bytes[i], g = bytes[i + 1], b = bytes[i + 2]
            if r < 80 && g > 150 && b < 80 { counts[0] += 1 }
            if r > 180 && g < 80 && b < 80 { counts[1] += 1 }
            if r > 180 && g > 180 && b < 80 { counts[2] += 1 }
            if r > 180 && g < 80 && b > 180 { counts[3] += 1 }
        }
        return counts.map { $0 > 10 }
    }

    private func redBounds(_ image: CGImage) throws -> CGRect {
        let bytes = try pixels(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                guard bytes[i] > 180, bytes[i + 1] < 80, bytes[i + 2] < 80 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "Expected actual red caption pixels")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func frameMarker(_ image: CGImage) throws -> Double {
        let bytes = try pixels(image)
        // Eight large binary blue bars tolerate H.264 color conversion while
        // distinguishing adjacent frames. No expected index comes from metadata.
        var index = 0
        for bit in 0..<8 {
            let blue = bytes[(image.width * (image.height / 2) + bit * 12 + 6) * 4 + 2]
            if blue > 128 { index |= 1 << bit }
        }
        return Double(index)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PreviewContract-\(UUID().uuidString)")
    }

    private func fixture(root: URL, fps: Int, times: [Double]? = nil, mediaStart: Double = 0, duration: Double = 2, height: Int = 180) async throws -> (AppStore, DemoProject, URL) {
        let repo = ProjectRepository(rootURL: root)
        let id = UUID()
        let target = try repo.prepareVideoRecordingURL(projectID: id)
        try await makeMovie(target.url, fps: fps, times: times, mediaStart: mediaStart, duration: duration, height: height)
        let project = DemoProject(id: id, name: "Synthetic changing frames",
            recording: VideoRecordingAsset(filename: target.filename, duration: duration,
                width: 320, height: height, mediaStartTime: mediaStart))
        var unbranded = project
        unbranded.theme.showsBranding = false
        try repo.saveProjects([unbranded])
        let store = AppStore(repository: repo)
        return (store, try XCTUnwrap(store.project(id: id)), target.url)
    }

    private func makeMovie(_ url: URL, fps: Int, times: [Double]?, mediaStart: Double, duration: Double, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: fps],
        ])
        // The default 600-tick writer timebase turns 59.94fps requests into
        // alternating rounded frame durations before production reads the file.
        input.mediaTimeScale = 60000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, time) in (times ?? (0..<(fps * 2)).map { Double($0) / Double(fps) }).enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &optional), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<320 {
                    let p = y * rowBytes + x * 4
                    base[p] = x < 96 && (index & (1 << (x / 12))) != 0 ? 220 : 30
                    base[p + 1] = 0
                    base[p + 2] = 0
                    base[p + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime:
                CMTime(value: Int64(((mediaStart + time) * 60000).rounded()), timescale: 60000)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(((mediaStart + duration) * 60000).rounded()), timescale: 60000))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func decodedFrames(_ url: URL) async throws -> [(time: Double, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        let context = CIContext()
        var frames: [(Double, CGImage)] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            frames.append((time.seconds,
                try XCTUnwrap(context.createCGImage(image, from: image.extent))))
        }
        XCTAssertEqual(reader.status, .completed)
        return frames
    }
}

/// Mounts the production screen-overlay canvas on the real playback clock.
/// Logical frame stepping verifies rendered states; it is not a wall-clock
/// display-refresh benchmark or a substitute for the workspace performance test.
private struct NativeFrameOverlayProbe: View {
    let project: DemoProject
    @ObservedObject var playback: VideoPlaybackModel

    var body: some View {
        VideoScreenOverlayCanvas(project: project, time: playback.currentTime,
            imageFrame: CGRect(x: 0, y: 0, width: 320, height: 180))
            .frame(width: 320, height: 180)
            .background(Color(red: 0, green: 0, blue: 1))
    }
}
