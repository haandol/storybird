import AVFoundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class VideoPlaybackTests: XCTestCase {
    func test_playbackReachesEditedTimelineEnd_playButtonReplaysFromStart() async throws {
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

        // Use only the same action as Play/Space, including after natural completion.
        for _ in 0..<3 {
            playback.togglePlayback()
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
            try await waitUntil {
                playback.currentTime > 0 && playback.currentTime < playback.duration
                    && playback.player.rate > 0
            }
            try await waitUntil {
                playback.player.rate == 0
                    && playback.player.currentTime().seconds >= playback.duration - 0.001
            }
            try await waitUntil { !playback.isPlaying }
            XCTAssertEqual(playback.currentTime, playback.duration, accuracy: 0.001)
        }
    }

    func test_playbackAtSeekedEnd_restartsButEarlierPositionsResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let media = try await TestVideoFactory.makeMovie(at: source, includeAudio: false)
        let project = DemoProject(name: "Playback seeking", recording: VideoRecordingAsset(
            filename: source.lastPathComponent, duration: media.duration,
            width: media.width, height: media.height
        ))
        let playback = VideoPlaybackModel(url: source, project: project)
        defer { playback.pause() }
        try await waitUntil { !playback.isPreparing && playback.player.currentItem?.status == .readyToPlay }
        XCTAssertNil(playback.errorMessage)

        playback.seek(to: 0.4)
        try await waitUntil { abs(playback.player.currentTime().seconds - 0.4) < 0.001 }
        playback.togglePlayback()
        XCTAssertEqual(playback.currentTime, 0.4, accuracy: 0.001)
        try await waitUntil { playback.currentTime > 0.5 && playback.isPlaying }
        playback.togglePlayback()
        XCTAssertFalse(playback.isPlaying)
        let pausedTime = playback.currentTime
        playback.togglePlayback()
        XCTAssertEqual(playback.currentTime, pausedTime, accuracy: 0.001)
        try await waitUntil { playback.currentTime > pausedTime && playback.isPlaying }
        playback.pause()

        // Being inside the final frame is still a valid resume position.
        let nearEnd = playback.duration - 1.0 / 600
        playback.seek(to: nearEnd)
        try await waitUntil { abs(playback.player.currentTime().seconds - nearEnd) < 0.001 }
        playback.togglePlayback()
        XCTAssertEqual(playback.currentTime, nearEnd, accuracy: 0.001)
        try await waitUntil { !playback.isPlaying }

        playback.seek(to: playback.duration)
        try await waitUntil { playback.player.currentTime().seconds >= playback.duration }
        playback.togglePlayback()
        XCTAssertEqual(playback.currentTime, 0, accuracy: 0.001)
        try await waitUntil {
            playback.currentTime > 0 && playback.currentTime < playback.duration
                && playback.player.rate > 0
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
