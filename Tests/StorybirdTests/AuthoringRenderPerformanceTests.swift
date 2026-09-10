import AppKit
@preconcurrency import AVFoundation
import AVKit
import QuartzCore
import StorybirdCore
import StorybirdMCPKit
import SwiftUI
import XCTest
@testable import Storybird

/// Opt-in native rendering evidence uses a temporary synthetic library and the
/// actual workspace, without capture permissions or production instrumentation.
@MainActor
final class AuthoringRenderPerformanceTests: XCTestCase {
    private let clock = ContinuousClock()
    private let width = 1920
    private let height = 1080
    private let fps = 30
    private let duration = 120.0
    private let layerCount = 100
    private let firstText = "IIIIIIII"
    private let secondText = "MMMMMMMM"
    private let firstColor = "#F01428"
    private let secondColor = "#14DC3C"

    /// Measures all 100 actions through decoded source pixels and mounted
    /// subtitle pixels; slow actions and readiness timeouts remain in the result.
    func test_renderedPreview_1080p120Seconds100Layers_95Of100ActionsWithin500ms() async throws {
        guard ProcessInfo.processInfo.environment["STORYBIRD_RUN_AUTHORING_RENDER_PERFORMANCE"] == "1" else {
            throw XCTSkip("Run this native performance test alone with STORYBIRD_RUN_AUTHORING_RENDER_PERFORMANCE=1.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthoringRenderPerformance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/authoring-render-performance")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let (store, project, source) = try await fixture(root: root)
        let metadata = try await verifySource(source)
        let workspace = ProjectWorkspaceView(store: store, projectID: project.id)
        let binding = workspace.projectBinding(for: project)
        let hosted = NSHostingView(rootView: workspace.frame(width: 760, height: 760)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        hosted.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil("workspace playhead") {
            self.descendants(hosted).contains { $0 is NSSlider }
        }
        let slider = try XCTUnwrap(descendants(hosted).compactMap { $0 as? NSSlider }.first)
        let controls = slider.convert(slider.bounds, to: nil)
        // The native layout test uses this same placeholder-center hit point.
        let point = NSPoint(x: 380, y: (controls.midY + 29 + 660) / 2)
        try mouse(.leftMouseDown, at: point, in: window)
        try mouse(.leftMouseUp, at: point, in: window)
        try await waitUntil("native player surface") {
            self.descendants(hosted).contains { $0 is AVPlayerView }
        }
        let surface = try XCTUnwrap(descendants(hosted).compactMap { $0 as? AVPlayerView }.first)
        let player = try XCTUnwrap(surface.player)
        try await waitUntil("player item ready") { player.currentItem?.status == .readyToPlay }
        let item = try XCTUnwrap(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        defer { item.remove(output) }
        let probe = FrameProbe()
        try snapshot(hosted, to: artifacts.appendingPathComponent("loaded-workspace.png"))

        // Two explicit unmeasured calibration states establish rendered glyph
        // masks. Their distinct shapes/colors must reject one another.
        try seek(slider, to: 0.4)
        try await waitUntil("calibration decoded source") {
            try self.decoded(output, player: player, surface: surface, time: 0.4, probe: probe)
        }
        let first = try await referenceMask(hosted, surface: surface, color: 1)
        try snapshot(hosted, to: artifacts.appendingPathComponent("calibration-first.png"))
        var calibration = binding.wrappedValue
        calibration.subtitles[0].text = secondText
        calibration.subtitles[0].style.backgroundHex = secondColor
        binding.wrappedValue = calibration
        let second = try await referenceMask(hosted, surface: surface, color: 2)
        try snapshot(hosted, to: artifacts.appendingPathComponent("calibration-second.png"))
        XCTAssertFalse(first.matches(second), "The pixel oracle must reject unchanged text/background.")
        XCTAssertFalse(second.matches(first), "A stale frame must not satisfy the opposite edit.")
        XCTAssertNotEqual(first.glyphs, second.glyphs, "Different words must produce different glyph pixels.")
        calibration = binding.wrappedValue
        calibration.subtitles[0].text = firstText
        calibration.subtitles[0].style.backgroundHex = firstColor
        binding.wrappedValue = calibration
        try await waitUntil("restored calibration") { try self.mask(hosted, surface: surface).matches(first) }
        let host = StorybirdExternalControlHost(store: store)
        var samples: [Sample] = []
        for index in 0..<50 {
            // Coprime traversal samples early/late times and forward/backward
            // jumps, visiting 50 distinct layers without per-action warmups.
            let layerIndex = (index * 37 + 11) % layerCount
            let time = Double(layerIndex * 36 + 12) / Double(fps)
            let seekStart = clock.now
            try seek(slider, to: time)
            let seekActionMS = milliseconds(since: seekStart)
            let sought = try await ready(hosted, surface: surface, output: output, player: player,
                probe: probe, time: time, expected: first, start: seekStart,
                actionMS: seekActionMS, index: index * 2, kind: "native-slider-seek")
            samples.append(sought)

            let current = binding.wrappedValue
            let subtitle = current.subtitles[layerIndex]
            let useHost = index.isMultiple(of: 2)
            let request = StorybirdControlRequest(name: "storybird_upsert_subtitle",
                argumentsJSON: try JSONSerialization.data(withJSONObject: [
                    "project_id": project.id.uuidString,
                    "expected_revision": current.revision,
                    "subtitle_id": subtitle.id.uuidString,
                    "start_time": subtitle.startTime, "end_time": subtitle.endTime,
                    "text": secondText, "background_hex": secondColor,
                ]))
            let editStart = clock.now
            if useHost {
                let response = await host.handle(request)
                XCTAssertFalse(response.isError, response.text)
            } else {
                var changed = current
                changed.subtitles[layerIndex].text = secondText
                changed.subtitles[layerIndex].style.backgroundHex = secondColor
                binding.wrappedValue = changed
            }
            let editActionMS = milliseconds(since: editStart)
            let edited = try await ready(hosted, surface: surface, output: output, player: player,
                probe: probe, time: time, expected: second, start: editStart,
                actionMS: editActionMS, index: index * 2 + 1,
                kind: useHost ? "mcp-host-subtitle-edit" : "ui-binding-subtitle-edit")
            samples.append(edited)
            XCTAssertEqual(binding.wrappedValue.subtitles.count, layerCount)
            XCTAssertEqual(binding.wrappedValue.subtitles[layerIndex].text, secondText)
            XCTAssertNil(store.errorMessage)
        }
        try snapshot(hosted, to: artifacts.appendingPathComponent("final-workspace.png"))
        let sorted = samples.map(\.totalMS).sorted()
        let p95 = sorted[94]
        let successes = samples.filter { $0.ready && $0.totalMS <= 500 }.count
        let report = Report(source: metadata, samples: samples, p95MS: p95,
            successes: successes, failures: samples.count - successes,
            readinessTimeouts: samples.filter { !$0.ready }.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: artifacts.appendingPathComponent("results.json"), options: .atomic)
        print("AUTHORING_RENDER_S5 \(width)x\(height) duration=\(duration)s fps=\(fps) layers=\(layerCount) "
            + "actions=100 <=500ms=\(successes) failures=\(100 - successes) p95=\(p95)ms "
            + "timeouts=\(report.readinessTimeouts) report=\(artifacts.path)/results.json")
        XCTAssertEqual(samples.count, 100)
        XCTAssertEqual(report.readinessTimeouts, 0, "See results.json for the unresolved source/overlay stage.")
        XCTAssertGreaterThanOrEqual(successes, 95, "Genuine action-to-render response exceeded the 500ms goal.")
        XCTAssertLessThanOrEqual(p95, 500)
    }

    private struct Source: Codable {
        let width: Int
        let height: Int
        let duration: Double
        let fps: Double
        let frames: Int
        let timedLayers: Int
        let schedule: String
    }

    private struct Sample: Codable {
        let index: Int
        let kind: String
        let projectTime: Double
        let actionMS: Double
        let decodedMS: Double?
        let overlayMS: Double?
        let totalMS: Double
        let ready: Bool
        let unresolvedStage: String
        let decodedFrame: Int
        let decodedTime: Double
        let sourceDiagnostic: String
    }

    private struct Report: Encodable {
        let source: Source
        let samples: [Sample]
        let p95MS: Double
        let successes: Int
        let failures: Int
        let readinessTimeouts: Int
        let measurement = "Native control/binding or MCP host action through decoded source frame/time, "
            + "AVPlayerView readiness and mounted SwiftUI glyph/background pixels; includes polling and snapshot overhead. "
            + "Decoded frame counter must exactly match returned PTS; returned PTS may differ from the seek by at most one source frame."
        let environment = "Debug SwiftPM; onscreen 760x760 point native workspace; 50 seeks, 25 UI binding edits, "
            + "25 MCP host edits; two unmeasured calibration states; nearest-rank p95; 3000ms readiness deadline."
    }

    private final class FrameProbe {
        var frame = -1
        var time = -1.0
        var diagnostic = ""
        var lastCopyReturnedBuffer = false
        var outputSize = "none"
    }

    private struct PixelMask {
        let values: [UInt8]
        let glyphs: Set<Int>
        let background: Set<Int>
        let color: UInt8

        /// Compares actual colored and glyph pixels rather than a whole-image
        /// similarity score that could conceal a small unchanged subtitle.
        func matches(_ expected: PixelMask) -> Bool {
            guard values.count == expected.values.count, color == expected.color,
                  !expected.glyphs.isEmpty, !expected.background.isEmpty else { return false }
            let glyphDifference = glyphs.symmetricDifference(expected.glyphs).count
            let backgroundDifference = background.symmetricDifference(expected.background).count
            return glyphDifference <= max(2, expected.glyphs.count / 100)
                && backgroundDifference <= max(2, expected.background.count / 100)
        }
    }

    /// Keeps every sample until its rendered state arrives or the explicit
    /// deadline expires, retaining separate action, decode, and overlay stages.
    private func ready(_ view: NSView, surface: AVPlayerView, output: AVPlayerItemVideoOutput,
        player: AVPlayer, probe: FrameProbe, time: Double, expected: PixelMask,
        start: ContinuousClock.Instant, actionMS: Double, index: Int, kind: String) async throws -> Sample {
        var decodedMS: Double?
        var overlayMS: Double?
        var isDecoded = false
        var isOverlay = false
        repeat {
            isDecoded = try decoded(output, player: player, surface: surface, time: time, probe: probe)
            if isDecoded && decodedMS == nil { decodedMS = milliseconds(since: start) }
            isOverlay = try mask(view, surface: surface).matches(expected)
            if isOverlay && overlayMS == nil { overlayMS = milliseconds(since: start) }
            if isDecoded && isOverlay { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        } while milliseconds(since: start) < 3000
        let total = milliseconds(since: start)
        let sample = Sample(index: index, kind: kind, projectTime: time, actionMS: actionMS,
            decodedMS: decodedMS, overlayMS: overlayMS, totalMS: total,
            ready: isDecoded && isOverlay,
            unresolvedStage: [isDecoded ? nil : "decoded-source/player-surface",
                isOverlay ? nil : "rendered-subtitle-pixels"].compactMap { $0 }.joined(separator: ","),
            decodedFrame: probe.frame, decodedTime: probe.time,
            sourceDiagnostic: "\(probe.diagnostic) outputSize=\(probe.outputSize) "
                + "lastCopyReturnedBuffer=\(probe.lastCopyReturnedBuffer)")
        print("RENDER_SAMPLE \(index) \(kind) time=\(time) action=\(actionMS)ms "
            + "decode=\(decodedMS.map(String.init(describing:)) ?? "missing")ms "
            + "overlay=\(overlayMS.map(String.init(describing:)) ?? "missing")ms total=\(total)ms "
            + "ready=\(sample.ready) stage=\(sample.unresolvedStage)")
        if !sample.ready { print("RENDER_TIMEOUT \(index) requested=\(time) \(sample.sourceDiagnostic)") }
        return sample
    }

    /// A source frame is ready only when the real player reaches the seek time,
    /// its surface is ready, and twelve encoded blue bits identify its actual
    /// presentation timestamp. The source and request may differ by one frame,
    /// accommodating native slider normalization without admitting stale seeks.
    private func decoded(_ output: AVPlayerItemVideoOutput, player: AVPlayer,
        surface: AVPlayerView, time: Double, probe: FrameProbe) throws -> Bool {
        let requested = CMTime(seconds: time, preferredTimescale: 600)
        var displayTime = CMTime.invalid
        probe.lastCopyReturnedBuffer = false
        if let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayTime) {
            probe.lastCopyReturnedBuffer = true
            probe.outputSize = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return false }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var frame = 0
            for bit in 0..<12 {
                let offset = height / 2 * stride + (bit * 80 + 40) * 4
                if base[offset] > 128 { frame |= 1 << bit }
                guard base[offset + 1] < 35, base[offset + 2] < 35 else { return false }
            }
            probe.frame = frame
            probe.time = displayTime.seconds
        }
        let diagnostic = "frame=\(probe.frame) outputTime=\(probe.time) playerTime=\(player.currentTime().seconds) "
            + "surfaceReady=\(surface.isReadyForDisplay) itemReady=\(player.currentItem?.status == .readyToPlay)"
        if probe.diagnostic != diagnostic {
            print("SOURCE_PROBE \(diagnostic)")
            probe.diagnostic = diagnostic
        }
        let oneFrame = 1 / Double(fps)
        return surface.isReadyForDisplay && player.currentItem?.status == .readyToPlay
            && abs(player.currentTime().seconds - time) <= oneFrame + 0.000001
            && probe.frame >= 0 && probe.frame < Int(duration) * fps
            && abs(probe.time - Double(probe.frame) / Double(fps)) < 0.000001
            && abs(probe.time - time) <= oneFrame + 0.000001
    }

    /// Uses the workspace's actual NSSlider target/action so SwiftUI's seek
    /// binding, player seek, overlay invalidation, and rendering are all timed.
    /// SwiftUI normalizes its native control independently of the project range.
    private func seek(_ slider: NSSlider, to time: Double) throws {
        slider.doubleValue = slider.minValue + time / duration * (slider.maxValue - slider.minValue)
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target), "Native slider action was not delivered.")
    }

    /// Calibrates stable rendered glyphs only after the intended opaque color
    /// and visible white text appear; no project query can satisfy this gate.
    private func referenceMask(_ view: NSView, surface: AVPlayerView, color: UInt8) async throws -> PixelMask {
        var previous: PixelMask?
        var stable = 0
        let start = clock.now
        repeat {
            let value = try mask(view, surface: surface)
            if value.color == color && value.glyphs.count > 20 && value.background.count > 100 {
                if let previous, value.matches(previous) { stable += 1 } else { stable = 0 }
                previous = value
                if stable >= 2 { return value }
            }
            try await Task.sleep(for: .milliseconds(10))
        } while milliseconds(since: start) < 5000
        throw NSError(domain: "AuthoringRenderPerformance", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Rendered subtitle calibration color \(color) did not appear."])
    }

    /// Captures the mounted SwiftUI host over its native video rectangle.
    /// Source pixels are independently decoded because AVPlayer's video plane
    /// is not guaranteed to be included by AppKit's view-cache snapshot.
    private func mask(_ view: NSView, surface: AVPlayerView) throws -> PixelMask {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let rect = surface.convert(surface.bounds, to: view)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var values = [UInt8](repeating: 0, count: image.width * image.height)
        var glyphs: Set<Int> = []
        var red: Set<Int> = []
        var green: Set<Int> = []
        for index in values.indices {
            let offset = index * 4
            let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
            if r > 180 && g < 80 && b < 100 { values[index] = 1; red.insert(index) }
            else if r < 80 && g > 160 && b < 110 { values[index] = 2; green.insert(index) }
            else if r > 210 && g > 210 && b > 210 { values[index] = 3; glyphs.insert(index) }
        }
        let color: UInt8 = red.count > green.count ? 1 : 2
        return PixelMask(values: values, glyphs: glyphs, background: color == 1 ? red : green, color: color)
    }

    /// Supplies a real 3600-frame, 30fps H.264 source and 100 consecutive
    /// timed subtitles; one subtitle is active at each measured seek point.
    private func fixture(root: URL) async throws -> (AppStore, DemoProject, URL) {
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let target = try repository.prepareVideoRecordingURL(projectID: id)
        try await movie(target.url)
        var project = DemoProject(id: id, name: "Synthetic rendered-performance workload",
            recording: VideoRecordingAsset(filename: target.filename, duration: duration, width: width, height: height))
        project.theme.showsBranding = false
        project.subtitles = (0..<layerCount).map { index in
            TimedSubtitle(startTime: Double(index) * 1.2, endTime: Double(index + 1) * 1.2,
                text: firstText, position: .bottom,
                style: TextOverlayStyle(backgroundHex: firstColor,
                    backgroundOpacity: 1, foregroundHex: "#FFFFFF", fontSize: 48))
        }
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        XCTAssertEqual(store.project(id: id)?.subtitles.count, 100)
        return (store, try XCTUnwrap(store.project(id: id)), target.url)
    }

    /// Encodes changing blue video with twelve large binary frame-number bars,
    /// preserving frame identity despite H.264 chroma conversion.
    private func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(Int(duration) * fps) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optional: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &optional)
            XCTAssertEqual(status, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let row = base.assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let blue = x < 960 ? ((frame & (1 << (x / 80))) != 0 ? 220 : 30) : 40 + frame % 80
                row[x] = 0xFF000000 | UInt32(blue)
            }
            for y in 1..<height { memcpy(base.advanced(by: y * rowBytes), base, width * 4) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
            else { throw try XCTUnwrap(writer.error) }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    /// Decodes every frame and timestamp so codec marker buffers, sparse
    /// fixtures, or incorrect metadata cannot masquerade as a 30fps baseline.
    private func verifySource(_ url: URL) async throws -> Source {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        let length = try await asset.load(.duration).seconds
        guard size == CGSize(width: width, height: height),
              abs(Double(rate) - Double(fps)) < 0.01, abs(length - duration) < 0.0001 else {
            throw NSError(domain: "AuthoringRenderPerformance", code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Fixture baseline mismatch: size=\(size), fps=\(rate), duration=\(length)."])
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard count < 3600, time.isFinite, abs(time - Double(count) / Double(fps)) < 0.0001 else {
                reader.cancelReading()
                throw NSError(domain: "AuthoringRenderPerformance", code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Fixture cadence mismatch at decoded frame \(count): time=\(time)."])
            }
            count += 1
        }
        guard reader.status == .completed, count == 3600 else {
            throw NSError(domain: "AuthoringRenderPerformance", code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "Fixture decoding incomplete: frames=\(count), status=\(reader.status.rawValue)."])
        }
        print("SOURCE_BASELINE \(Int(size.width))x\(Int(size.height)) duration=\(length)s fps=\(rate) "
            + "decodedFrames=\(count) layers=\(layerCount)")
        return Source(width: Int(size.width), height: Int(size.height), duration: length, fps: Double(rate),
            frames: count, timedLayers: layerCount, schedule: "100 consecutive 1.2-second subtitles; one active per sampled time")
    }

    /// Finds controls only inside the owned workspace, avoiding other agents'
    /// native windows and all accessibility or global event APIs.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Loads the preview through real native mouse dispatch local to the test
    /// window; it never moves the system pointer or controls another window.
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }

    /// Startup waits yield to the native run loop and fail explicitly when the
    /// real surface cannot become ready; these are outside measured actions.
    private func waitUntil(_ stage: String, condition: () throws -> Bool) async throws {
        let start = clock.now
        repeat {
            if try condition() { return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        } while milliseconds(since: start) < 10000
        throw NSError(domain: "AuthoringRenderPerformance", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out awaiting \(stage)."])
    }

    /// Uses monotonic elapsed time including synchronous mutation and rendering
    /// work, so wall-clock changes cannot improve the measured percentile.
    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: clock.now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    /// Saves only the owned synthetic workspace under build output for review
    /// of the actual calibration and final rendered appearance.
    private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
