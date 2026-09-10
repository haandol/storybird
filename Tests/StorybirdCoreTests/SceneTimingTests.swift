import Foundation
import StorybirdCore
import XCTest

final class SceneTimingTests: XCTestCase {
    func test_sceneLayers_followMoveSpeedFreezeAndSplitWithoutChangingDuration() throws {
        var project = fixture()
        let owner = project.clips[1].id
        let anchor = try SceneTiming.anchor(at: 12, in: project)
        project.narrations = [NarrationClip(
            voiceProfileID: UUID(), filename: "voice.wav", text: "Explain",
            startTime: 12, duration: 1, sceneAnchor: anchor
        )]
        project.subtitles = [TimedSubtitle(
            startTime: 12, endTime: 13, text: "Explain", sceneAnchor: anchor
        )]
        let moved = try VideoTimelineEditor.move(project: project, clipID: owner, destination: 0)
        XCTAssertEqual(moved.narrations[0].startTime, 2)
        XCTAssertEqual(moved.subtitles[0].startTime, 2)
        let sped = try VideoTimelineEditor.setSpeed(project: moved, clipID: owner, rate: 2)
        XCTAssertEqual(sped.narrations[0].startTime, 1)
        XCTAssertEqual(sped.narrations[0].duration, 1)
        XCTAssertEqual(sped.subtitles[0].endTime, 2)
        let frozen = try VideoTimelineEditor.insertFreeze(
            project: project, after: project.clips[0].id, sourceTime: 9, duration: 3
        )
        XCTAssertEqual(frozen.narrations[0].startTime, 15)
        let split = try VideoTimelineEditor.split(project: project, clipID: owner, sourceTime: 12)
        XCTAssertEqual(split.narrations.count, 1)
        XCTAssertEqual(split.narrations[0].sceneAnchor?.clipID, split.clips[2].id)
        for edited in [moved, sped, frozen, split] { try VideoProjectValidator.validate(edited) }
    }

    func test_sceneLayers_trimDeleteAndFixedTimeUseDifferentLifetimes() throws {
        var project = fixture()
        let anchor = try SceneTiming.anchor(at: 12, in: project)
        project.narrations = [
            NarrationClip(voiceProfileID: UUID(), filename: "scene.wav", text: "scene", startTime: 12, duration: 1, sceneAnchor: anchor),
            NarrationClip(voiceProfileID: UUID(), filename: "fixed.wav", text: "fixed", startTime: 15, duration: 1),
        ]
        let trimmed = try VideoTimelineEditor.trim(
            project: project, clipID: project.clips[1].id, sourceStart: 13, sourceEnd: 20
        )
        XCTAssertEqual(trimmed.narrations.map(\.text), ["fixed"])
        XCTAssertEqual(trimmed.narrations[0].startTime, 15)
        let removed = try VideoTimelineEditor.delete(project: project, clipID: project.clips[1].id)
        XCTAssertEqual(removed.narrations.map(\.text), ["fixed"])
        XCTAssertThrowsError(try VideoProjectValidator.validate(removed))
    }

    func test_sceneLayers_freezeOwnerAndCardsAreUnambiguous() throws {
        var project = fixture()
        project = try VideoTimelineEditor.insertFreeze(
            project: project, after: project.clips[0].id, sourceTime: 9, duration: 3
        )
        let anchor = try SceneTiming.anchor(at: 11, in: project)
        project.narrations = [NarrationClip(
            voiceProfileID: UUID(), filename: "voice.wav", text: "Freeze",
            startTime: 11, duration: 1, sceneAnchor: anchor
        )]
        let moved = try VideoTimelineEditor.move(project: project, clipID: anchor.clipID, destination: 0)
        XCTAssertEqual(moved.narrations[0].startTime, 1)
        let titled = try DemoEffectEditor.insertTitle(in: moved, after: nil, duration: 2)
        XCTAssertEqual(titled.narrations[0].startTime, 3)
        try VideoProjectValidator.validate(titled)
        XCTAssertThrowsError(try SceneTiming.anchor(at: 1, in: titled))
        XCTAssertThrowsError(try SceneTiming.anchor(at: titled.timelineDuration, in: titled))
    }

    func test_sceneLayers_legacyDecodeKeepsFixedTimesAndMissingLanguageDefault() throws {
        let clip = NarrationClip(voiceProfileID: UUID(), filename: "old.wav", text: "Old", startTime: 1, duration: 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        json.removeValue(forKey: "language")
        json.removeValue(forKey: "sceneAnchor")
        let decoded = try JSONDecoder().decode(NarrationClip.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.sceneAnchor)
        XCTAssertEqual(decoded.language, "korean")
        XCTAssertEqual(decoded.startTime, 1)
    }

    private func fixture() -> DemoProject {
        DemoProject(
            name: "Scenes",
            recording: VideoRecordingAsset(filename: "video.mp4", duration: 20, width: 640, height: 480),
            clips: [VideoClip(sourceStart: 0, sourceEnd: 10), VideoClip(sourceStart: 10, sourceEnd: 20)]
        )
    }
}
