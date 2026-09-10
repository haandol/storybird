import Foundation
import XCTest
@testable import Storybird

@MainActor
final class VoicePreviewPlayerTests: XCTestCase {
    func test_previewClick_playsInternallyAndSecondClickStops() {
        let playback = SyntheticVoicePlayback()
        var requestedURLs: [URL] = []
        let player = VoicePreviewPlayer {
            requestedURLs.append($0)
            return playback
        }
        let url = URL(fileURLWithPath: "/synthetic/reference.wav")

        player.toggle(url)
        XCTAssertEqual(requestedURLs, [url])
        XCTAssertEqual(playback.playCount, 1)
        XCTAssertEqual(player.playingURL, url)
        XCTAssertNil(player.errorMessage)

        player.toggle(url)
        XCTAssertEqual(playback.stopCount, 1)
        XCTAssertEqual(requestedURLs, [url])
        XCTAssertNil(player.playingURL)
    }

    func test_replacement_stopsPreviousAndIgnoresItsLateCompletion() {
        let first = SyntheticVoicePlayback()
        let second = SyntheticVoicePlayback()
        let firstURL = URL(fileURLWithPath: "/synthetic/first.wav")
        let secondURL = URL(fileURLWithPath: "/synthetic/second.wav")
        let player = VoicePreviewPlayer { $0 == firstURL ? first : second }
        player.toggle(firstURL)
        let lateCompletion = first.onCompletion

        player.toggle(secondURL)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.playCount, 1)
        lateCompletion?("Old playback failed")
        XCTAssertEqual(player.playingURL, secondURL)
        XCTAssertNil(player.errorMessage)

        second.onCompletion?(nil)
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(second.stopCount, 1)
    }

    func test_stop_invalidatesCompletionAndAllowsReplay() {
        let playback = SyntheticVoicePlayback()
        let player = VoicePreviewPlayer { _ in playback }
        let url = URL(fileURLWithPath: "/synthetic/reference.wav")
        player.toggle(url)
        let lateCompletion = playback.onCompletion

        player.stop()
        XCTAssertNil(player.playingURL)
        XCTAssertNil(playback.onCompletion)
        lateCompletion?("Cancelled playback failed")
        XCTAssertNil(player.errorMessage)

        player.toggle(url)
        XCTAssertEqual(playback.playCount, 2)
        XCTAssertEqual(player.playingURL, url)
    }

    func test_unreadableFile_reportsErrorWithoutActivePlayback() {
        let player = VoicePreviewPlayer()
        player.toggle(URL(fileURLWithPath: "/nonexistent-\(UUID()).wav"))
        XCTAssertNil(player.playingURL)
        XCTAssertNotNil(player.errorMessage)
    }

    func test_playFailure_cleansUpAndSuccessfulRetryClearsError() {
        let playback = SyntheticVoicePlayback()
        playback.canPlay = false
        let player = VoicePreviewPlayer { _ in playback }
        let url = URL(fileURLWithPath: "/synthetic/reference.wav")
        player.toggle(url)
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(playback.stopCount, 1)
        XCTAssertNotNil(player.errorMessage)

        playback.canPlay = true
        player.toggle(url)
        XCTAssertEqual(player.playingURL, url)
        XCTAssertNil(player.errorMessage)
        playback.onCompletion?("Invalid audio")
        XCTAssertNil(player.playingURL)
        XCTAssertEqual(player.errorMessage, "Invalid audio")
    }
}

@MainActor
private final class SyntheticVoicePlayback: VoicePreviewPlayback {
    var onCompletion: ((String?) -> Void)?
    var canPlay = true
    var playCount = 0
    var stopCount = 0

    func play() -> Bool {
        playCount += 1
        return canPlay
    }

    func stop() { stopCount += 1 }
}
