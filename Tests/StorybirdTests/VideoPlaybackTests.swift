import AVFoundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class VideoPlaybackTests: XCTestCase {
    func test_playbackReachesEditedTimelineEnd_clearsPlayingState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let media = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
        var project = DemoProject(name: "Playback completion", recording: VideoRecordingAsset(
            filename: source.lastPathComponent, duration: media.duration,
            width: media.width, height: media.height
        ))
        project.clips[0].sourceEnd = 0.3
        let playback = VideoPlaybackModel(url: source, project: project)
        defer { playback.pause() }
        try await waitUntil { !playback.isPreparing && playback.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(playback.errorMessage)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.duration, 0.3, accuracy: 0.001)

        // Repeat after seeking back to catch completion observers that only work once.
        for _ in 0..<2 {
            await playback.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            playback.togglePlayback()
            XCTAssertTrue(playback.isPlaying)
            try await waitUntil {
                playback.player.rate == 0
                    && playback.player.currentTime().seconds >= playback.duration - 0.001
            }
            try await waitUntil { !playback.isPlaying }
            XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
        }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail("Playback did not reach the expected state.", file: file, line: line)
            throw NSError(domain: "VideoPlaybackTests", code: 1)
        }
    }
}
