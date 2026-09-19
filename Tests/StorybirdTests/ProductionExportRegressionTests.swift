import AVFoundation
import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class ProductionExportRegressionTests: XCTestCase {
    /// Reuses only the reported timing boundaries, with synthetic pixels and tones.
    func test_sixEditedClipsWithNarration_exportsEveryInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.mp4")
        let media = try await TestVideoFactory.makeMovie(
            at: source, includeAudio: false, duration: 90
        )
        let lengths = [10.4, 8.9, 9.6, 9.24, 12.04, 9.78]
        let starts = [0.4, 10.8, 19.7, 29.3, 38.54, 50.58]
        let durations = [9.44, 7.92, 8.64, 8.24, 11.04, 8.08]
        let gains = [3.3118, 5.6003, 2.9546, 3.2417, 3.4594, 3.4514]
        for index in durations.indices {
            try TestVideoFactory.makeToneWAV(
                at: root.appendingPathComponent("tone-\(index).wav"),
                duration: durations[index], frequency: 330 + Double(index) * 110
            )
        }
        for speedChanges in [true, false] {
            var project = DemoProject(name: "Synthetic six scenes", recording: VideoRecordingAsset(
                filename: source.lastPathComponent, duration: media.duration,
                width: media.width, height: media.height
            ))
            project.clips = lengths.indices.map { index in
                VideoClip(
                    sourceStart: Double(index) * 15,
                    sourceEnd: Double(index) * 15 + (speedChanges ? 15 : lengths[index]),
                    playbackRate: speedChanges ? 15 / lengths[index] : 1
                )
            }
            project.narrations = starts.indices.map { index in
                NarrationClip(
                    filename: "tone-\(index).wav", text: "Synthetic scene \(index)",
                    startTime: starts[index], duration: durations[index], volume: gains[index]
                )
            }
            project.subtitles = starts.indices.map { index in
                TimedSubtitle(startTime: starts[index], endTime: starts[index] + durations[index],
                              text: "Scene \(index + 1)")
            }
            let preview = try await AudioPreviewRenderer.render(
                project: project, sourceURL: source, startTime: 0, duration: project.timelineDuration
            )
            defer { try? FileManager.default.removeItem(atPath: preview.path) }
            XCTAssertEqual(preview.duration, project.timelineDuration, accuracy: 0.001)
            let output = root.appendingPathComponent("export-\(speedChanges).mp4")
            do {
                _ = try await LayeredVideoExporter().export(
                    project: project, sourceURL: source, destinationURL: output
                )
            } catch {
                let failure = error as NSError
                XCTFail("speedChanges=\(speedChanges), \(failure.domain) \(failure.code): \(failure.userInfo)")
                continue
            }
            let asset = AVURLAsset(url: output)
            let actualDuration = try await asset.load(.duration)
            XCTAssertEqual(actualDuration.seconds, project.timelineDuration, accuracy: 1 / 30)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1)
            for index in starts.indices {
                let amplitude = try await TestVideoFactory.averageAmplitude(
                    in: output, from: starts[index] + 0.2, to: starts[index] + 0.4
                )
                XCTAssertGreaterThan(amplitude, 0.05, "Missing narration \(index)")
            }
        }
    }
}
