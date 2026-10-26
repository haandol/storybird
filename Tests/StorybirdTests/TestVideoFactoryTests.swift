import AVFoundation
import XCTest
@testable import Storybird

final class TestVideoFactoryTests: XCTestCase {
    func test_syntheticMovies_preserveTracksTimingDimensionsAndTransform() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, type, audio, displaySize): (String, AVFileType, Bool, CGSize?) in [
            ("plain.mp4", .mp4, false, nil),
            ("plain.mov", .mov, false, nil),
            ("audio.mp4", .mp4, true, nil),
            ("scaled.mp4", .mp4, false, CGSize(width: 128, height: 96)),
        ] {
            let url = root.appendingPathComponent(name)
            let result = try await TestVideoFactory.makeMovie(
                at: url, fileType: type, includeAudio: audio, duration: 1,
                width: 64, height: 48, displaySize: displaySize
            )
            XCTAssertEqual(result.width, 64)
            XCTAssertEqual(result.height, 48)
            XCTAssertEqual(result.duration, 1, accuracy: 1.0 / 600)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            XCTAssertEqual(tracks.count, 1)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, audio ? 1 : 0)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 1, accuracy: 1.0 / 30)
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            XCTAssertEqual(size.applying(transform), displaySize ?? CGSize(width: 64, height: 48))

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                               Double(count) / 30, accuracy: 1.0 / 600)
                count += 1
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(count, 30, name)
            if audio {
                let amplitude = try await TestVideoFactory.averageAmplitude(in: url, from: 0.1, to: 0.9)
                XCTAssertGreaterThan(amplitude, 0.1)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(Set(files), ["plain.mp4", "plain.mov", "audio.mp4", "scaled.mp4"])
    }

    func test_existingDestination_preservesOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("existing.mp4")
        let original = Data("existing destination".utf8)
        try original.write(to: url)
        do {
            _ = try await TestVideoFactory.makeMovie(at: url, includeAudio: false)
            XCTFail("An existing destination must not be replaced")
        } catch {
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.mp4"])
    }

    func test_amplitudeWindow_distinguishesToneFromLeadingAndTrailingSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("delayed-audio.mp4")
        _ = try await TestVideoFactory.makeMovie(
            at: url, includeAudio: true, audioStart: 0.25, audioDuration: 0.5, duration: 1
        )
        let leading = try await TestVideoFactory.averageAmplitude(in: url, from: 0, to: 0.15)
        let tone = try await TestVideoFactory.averageAmplitude(in: url, from: 0.35, to: 0.65)
        let trailing = try await TestVideoFactory.averageAmplitude(in: url, from: 0.85, to: 1)
        XCTAssertLessThan(leading, 0.01)
        XCTAssertGreaterThan(tone, 0.1)
        XCTAssertLessThan(trailing, 0.01)
    }
}
