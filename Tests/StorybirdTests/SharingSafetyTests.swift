import AVFoundation
import Foundation
import MCP
import StorybirdCore
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class SharingSafetyTests: XCTestCase {
    private typealias Response = (content: [Tool.Content], isError: Bool?)
    private struct Job: Decodable { let id: UUID; let state: String; let progress: Double; let outputPath: String?; let error: String? }

    func test_createNewPublication_rejectsDestinationAppearingDuringRender() async throws {
        let (root, _, project, source) = try await fixture(duration: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("collision.mp4"), sentinel = Data("Existing output".utf8)
        do {
            _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: destination,
                destinationPolicy: .createNew, progress: { _ in try? sentinel.write(to: destination, options: .withoutOverwriting) })
            XCTFail("A concurrent destination must not be overwritten")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".storybird-export-") })
        }
    }

    func test_exportCannotReplaceAnyOwnedSource_evenWhenPrimaryIsDifferent() async throws {
        let (root, store, initial, source) = try await fixture(duration: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second.mp4")
        _ = try await TestVideoFactory.makeMovie(at: second, includeAudio: true, duration: 1)
        let registered = try await store.importProjectMedia(projectID: initial.id, sourceURL: second)
        let project = try XCTUnwrap(store.project(id: initial.id))
        let owned = store.repository.assetURL(projectID: project.id, filename: registered.filename)
        let before = try Data(contentsOf: owned)
        do {
            _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: owned)
            XCTFail("A second immutable source is not an export destination")
        } catch {
            XCTAssertEqual(try Data(contentsOf: owned), before)
            XCTAssertEqual(store.project(id: project.id), project)
        }
    }

    func test_asyncExport_compactSnapshotCancelAndTerminalStatesPreserveSource() async throws {
        let (root, store, initial, source) = try await fixture(duration: 10)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBytes = try Data(contentsOf: source)
        var project = initial
        project = try MaskEditor.create(in: project, startTime: 0, endTime: 10, x: 0, y: 0, width: 1, height: 1,
            timingMode: .project, coordinateSpace: .canvas, colorHex: "#FF0000")
        project = try store.saveProject(project, expectedRevision: project.revision)
        try await withClient(store: store) { client in
            let started: Job = try decode(await client.callTool(name: "storybird_start_export", arguments: [
                "project_id": .string(project.id.uuidString), "parent_directory": .string(root.path)]))
            XCTAssertNil(started.outputPath)
            let duplicate = try await client.callTool(name: "storybird_start_export", arguments: [
                "project_id": .string(project.id.uuidString), "parent_directory": .string(root.path)])
            XCTAssertEqual(duplicate.isError, true)
            var newer = try XCTUnwrap(store.project(id: project.id))
            if case var .mask(mask) = newer.effects[0] { mask.colorHex = "#0000FF"; newer.effects[0] = .mask(mask) }
            newer = try store.saveProject(newer, expectedRevision: newer.revision)
            let completed = try await terminal(client, id: started.id)
            XCTAssertEqual(completed.state, "completed", completed.error ?? "")
            XCTAssertEqual(completed.progress, 100)
            let url = URL(fileURLWithPath: try XCTUnwrap(completed.outputPath))
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            let center = try pixel(frame)
            XCTAssertGreaterThan(center[0], 235)
            XCTAssertLessThan(center[2], 20, "The export must use its initial red snapshot, not the new blue state")
            let afterCancel: Job = try decode(await client.callTool(name: "storybird_cancel_export", arguments: ["job_id": .string(started.id.uuidString)]))
            XCTAssertEqual(afterCancel.state, "completed")
            XCTAssertEqual(afterCancel.outputPath, completed.outputPath)
            let cancelJob: Job = try decode(await client.callTool(name: "storybird_start_export", arguments: [
                "project_id": .string(project.id.uuidString), "parent_directory": .string(root.path)]))
            _ = try await client.callTool(name: "storybird_cancel_export", arguments: ["job_id": .string(cancelJob.id.uuidString)])
            let cancelled = try await terminal(client, id: cancelJob.id)
            XCTAssertEqual(cancelled.state, "cancelled", cancelled.error ?? "")
            XCTAssertNil(cancelled.outputPath)
            let repeated: Job = try decode(await client.callTool(name: "storybird_cancel_export", arguments: ["job_id": .string(cancelJob.id.uuidString)]))
            XCTAssertEqual(repeated.state, "cancelled")
            let missing = try await client.callTool(name: "storybird_get_export", arguments: ["job_id": .string(UUID().uuidString)])
            XCTAssertEqual(missing.isError, true)
            XCTAssertEqual(store.project(id: project.id), newer)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".storybird-export-") })
        }
    }

    func test_mixedFrameRatesAndReordering_keepPrimaryCadenceAndEachSourcesAudio() async throws {
        let (root, store, initial, source) = try await fixture(duration: 2, audio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secondary = root.appendingPathComponent("fast-source.mp4")
        _ = try await TestVideoFactory.makeMovie(at: secondary, includeAudio: true, toneFrequency: 770, duration: 1,
            width: 320, height: 180, frameRate: 60)
        let second = try await store.importProjectMedia(projectID: initial.id, sourceURL: secondary)
        let image = root.appendingPathComponent("still.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        try ProjectMediaFiles.png(XCTUnwrap(context.makeImage())).write(to: image)
        let still = try await store.importProjectMedia(projectID: initial.id, sourceURL: image)
        var project = try store.placeMediaAsset(projectID: initial.id, assetID: second.id, expectedRevision: initial.revision,
            destination: 1, sourceStart: 0.2, sourceEnd: 0.8)
        project = try store.placeMediaAsset(projectID: initial.id, assetID: still.id, expectedRevision: project.revision,
            destination: 1, duration: 0.4)
        let narration = root.appendingPathComponent("still-tone.wav")
        try TestVideoFactory.makeToneWAV(at: narration, duration: 0.4, frequency: 1100)
        let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: narration)
        project = try store.placeAudioAsset(projectID: project.id, assetID: asset.id, expectedRevision: project.revision,
            startTime: 2, timingMode: .scene)
        project = try store.saveProject(VideoTimelineEditor.move(project: project, clipID: project.clips[2].id, destination: 0), expectedRevision: project.revision)
        XCTAssertEqual(project.narrations[0].startTime, 2.6, accuracy: 0.000001)
        project.canvas.preset = .square
        project = try store.saveProject(project, expectedRevision: project.revision)
        let output = root.appendingPathComponent("mixed.mp4")
        _ = try await LayeredVideoExporter().export(project: project, sourceURL: source, destinationURL: output)
        let result = AVURLAsset(url: output)
        let tracks = try await result.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(rate, 30, accuracy: 0.01)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1080))
        let inspected = DemoProject(name: "Inspect", recording: VideoRecordingAsset(filename: output.lastPathComponent, duration: project.timelineDuration, width: 1080, height: 1080))
        let preview = try await AudioPreviewRenderer.render(project: inspected, sourceURL: output, startTime: 0, duration: project.timelineDuration)
        defer { try? FileManager.default.removeItem(atPath: preview.path) }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: preview.path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let sampleRate = file.processingFormat.sampleRate
        func amplitude(_ frequency: Double, from start: Double, to end: Double) -> Double {
            let first = Int(start * sampleRate), last = min(Int(end * sampleRate), Int(buffer.frameLength))
            var cosine = 0.0, sine = 0.0
            for index in first..<last {
                let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
                cosine += Double(samples[index]) * cos(phase); sine += Double(samples[index]) * sin(phase)
            }
            return 2 * hypot(cosine, sine) / Double(last - first)
        }
        XCTAssertGreaterThan(amplitude(770, from: 0.15, to: 0.45), 0.05)
        XCTAssertLessThan(amplitude(330, from: 0.15, to: 0.45), 0.02)
        XCTAssertGreaterThan(amplitude(330, from: 0.9, to: 1.5), 0.05)
        XCTAssertLessThan(amplitude(770, from: 0.9, to: 1.5), 0.02)
        XCTAssertGreaterThan(amplitude(1100, from: 2.7, to: 2.9), 0.05)
        XCTAssertLessThan(amplitude(330, from: 2.7, to: 2.9), 0.02)
        XCTAssertLessThan(amplitude(770, from: 2.7, to: 2.9), 0.02)
    }

    private func terminal(_ client: Client, id: UUID) async throws -> Job {
        for _ in 0..<1000 {
            let job: Job = try decode(await client.callTool(name: "storybird_get_export", arguments: ["job_id": .string(id.uuidString)]))
            XCTAssertGreaterThanOrEqual(job.progress, 0); XCTAssertLessThanOrEqual(job.progress, 100)
            if ["completed", "failed", "cancelled"].contains(job.state) { return job }
            XCTAssertNil(job.outputPath)
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "SharingSafetyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export did not reach a terminal state"])
    }
    private func decode<T: Decodable>(_ response: Response) throws -> T {
        let text = response.content.compactMap { if case let .text(value, _, _) = $0 { value } else { nil } }.joined()
        XCTAssertNotEqual(response.isError, true, text)
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
    private func pixel(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (image.height / 2 * image.width + image.width / 2) * 4
        return Array(pixels[index..<(index + 3)])
    }
    private func fixture(duration: Double, audio: Bool = false) async throws -> (URL, AppStore, DemoProject, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-safety-\(UUID())")
        let repository = ProjectRepository(rootURL: root), id = UUID()
        let source = try repository.prepareVideoRecordingURL(projectID: id)
        let video = try await TestVideoFactory.makeMovie(at: source.url, includeAudio: audio, toneFrequency: 330, duration: duration, width: 640, height: 360)
        var project = DemoProject(id: id, name: "Safe export", recording: VideoRecordingAsset(filename: source.filename, duration: video.duration, width: video.width, height: video.height, hasAudio: audio))
        project.theme.showsBranding = false
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (root, store, try XCTUnwrap(store.project(id: id)), source.url)
    }
    private func withClient(store: AppStore, body: @MainActor (Client) async throws -> Void) async throws {
        let host = StorybirdExternalControlHost(store: store)
        let service = StorybirdMCPService(client: StorybirdAppIPCClient(sender: { await host.handle($0) }, launcher: { throw StorybirdControlWireError.invalidMessage }))
        let transport = await InMemoryTransport.createConnectedPair()
        let server = try await service.startServer(transport: transport.server)
        let client = Client(name: "Sharing protocol verification", version: "1")
        do { _ = try await client.connect(transport: transport.client); try await body(client); await client.disconnect(); await server.stop() }
        catch { await client.disconnect(); await server.stop(); throw error }
    }
}
