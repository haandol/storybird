import Foundation
import XCTest
@testable import StorybirdCore

final class TimelineClipEditingTests: XCTestCase {
    func test_trimExtension_usesReferencedOriginalBoundsAndPreservesRateAndIdentity() throws {
        var project = fixture()
        let secondary = ProjectMediaAsset(kind: .video, filename: "second.mp4", name: "Second",
            width: 100, height: 100, duration: 10)
        project.mediaAssets = [secondary]
        project.clips = [VideoClip(sourceStart: 2, sourceEnd: 4, playbackRate: 2, mediaAssetID: secondary.id)]
        let id = project.clips[0].id
        let extended = try VideoTimelineEditor.trim(project: project, clipID: id, sourceStart: 0, sourceEnd: 10)
        try VideoProjectValidator.validate(extended)
        XCTAssertEqual(extended.clips[0].id, id)
        XCTAssertEqual(extended.clips[0].playbackRate, 2)
        XCTAssertEqual(extended.clips[0].mediaAssetID, secondary.id)
        XCTAssertEqual(extended.timelineDuration, 5)
        for (start, end) in [(-0.001, 2.0), (0.0, 10.001), (2.0, 2.0), (0.0, .infinity)] {
            XCTAssertThrowsError(try VideoTimelineEditor.trim(project: project, clipID: id, sourceStart: start, sourceEnd: end))
        }
        XCTAssertEqual(project.clips[0].sourceStart, 2)
    }

    func test_heldSplit_boundaryStartMovesRightAndSpanningEffectKeepsContinuousTime() throws {
        for kind in [VideoClipKind.freeze, .image] {
            var project = fixture()
            let image = ProjectMediaAsset(kind: .image, filename: "still.png", name: "Still", width: 100, height: 100)
            if kind == .image { project.mediaAssets = [image] }
            project.clips = [VideoClip(kind: kind, sourceStart: kind == .image ? 0 : 1,
                sourceEnd: kind == .image ? 0 : 1, freezeDuration: 6,
                mediaAssetID: kind == .image ? image.id : nil, placement: MediaPlacement(mode: .fill, anchorX: 0.3))]
            let original = project.clips[0]
            let boundary = try SceneTiming.anchor(at: 2, in: project)
            project.subtitles = [TimedSubtitle(startTime: 2, endTime: 3, text: "Boundary", sceneAnchor: boundary)]
            project = try VideoTimelineEditor.addClickCue(to: project, at: 2, x: 0.5, y: 0.5)
            project.effects = [VideoTimelineEditor.anchorContentEffect(.spotlight(SpotlightEffect(
                startTime: 1, endTime: 4, x: 0.2, y: 0.2, width: 0.2, height: 0.2)), in: project, at: 1)]
            let result = try VideoTimelineEditor.splitHeld(project: project, clipID: original.id, clipOffset: 2)
            try VideoProjectValidator.validate(result)
            XCTAssertEqual(result.clips.map(\.outputDuration), [2, 4])
            XCTAssertEqual(result.timelineDuration, 6)
            XCTAssertTrue(result.clips.allSatisfy { $0.placement == original.placement && $0.mediaAssetID == original.mediaAssetID })
            XCTAssertEqual(result.subtitles[0].sceneAnchor?.clipID, result.clips[1].id)
            XCTAssertEqual(result.subtitles[0].sceneAnchor?.clipOffset, 0)
            XCTAssertEqual(result.subtitles[0].startTime, 2)
            XCTAssertEqual(result.clicks[0].sourceAnchor?.clipID, result.clips[1].id)
            XCTAssertEqual(result.clicks[0].sourceAnchor?.clipOffset, 0)
            XCTAssertEqual(result.effects.map(\.startTime), [1, 2])
            XCTAssertEqual(result.effects.map(\.endTime), [2, 4])
            XCTAssertEqual(Set(result.effects.map(\.id)).count, 2)
            for offset in [0.0, 6, -1, .nan] {
                XCTAssertThrowsError(try VideoTimelineEditor.splitHeld(project: project, clipID: original.id, clipOffset: offset))
            }
        }
    }

    func test_duplicateScene_createsIndependentLinkedLayersWithoutCopyingFixedLayers() throws {
        var project = fixture()
        let owner = project.clips[0]
        let anchor = try SceneTiming.anchor(at: 1, in: project)
        project.subtitles = [TimedSubtitle(startTime: 1, endTime: 2, text: "Linked", sceneAnchor: anchor),
            TimedSubtitle(startTime: 0, endTime: 0.5, text: "Fixed")]
        project.narrations = [NarrationClip(filename: "voice.wav", text: "Voice", startTime: 1,
            duration: 1, sceneAnchor: anchor)]
        project = try VideoTimelineEditor.addClickCue(to: project, at: 1, x: 0.5, y: 0.5)
        project.effects = [VideoTimelineEditor.anchorContentEffect(.spotlight(SpotlightEffect(
            startTime: 0.5, endTime: 1.5, x: 0.2, y: 0.2, width: 0.2, height: 0.2)), in: project, at: 1)]
        project.clicks[0].sourceAnchor = nil
        let result = try VideoTimelineEditor.duplicate(project: project, clipID: owner.id, destination: 0)
        try VideoProjectValidator.validate(result)
        let newID = result.clips[0].id
        XCTAssertNotEqual(newID, owner.id)
        XCTAssertEqual(result.clips[1].id, owner.id)
        XCTAssertEqual(result.timelineDuration, 12)
        XCTAssertEqual(result.subtitles.count, 3)
        XCTAssertEqual(result.subtitles.filter { $0.sceneAnchor == nil }, project.subtitles.filter { $0.sceneAnchor == nil })
        XCTAssertEqual(result.subtitles.first { $0.sceneAnchor?.clipID == newID }?.startTime, 1)
        XCTAssertEqual(result.subtitles.first { $0.id == project.subtitles[0].id }?.startTime, 7)
        XCTAssertEqual(result.narrations.count, 2)
        XCTAssertEqual(Set(result.narrations.map(\.assetID)).count, 1)
        XCTAssertEqual(Set(result.narrations.map(\.id)).count, 2)
        XCTAssertEqual(result.clicks.first { $0.id == project.clicks[0].id }?.time, 7)
        XCTAssertEqual(result.clicks.first { $0.id != project.clicks[0].id }?.time, 1)
        XCTAssertEqual(Set(result.suggestions.map(\.clickID)), Set(result.clicks.map(\.id)))
        XCTAssertEqual(Set(result.suggestions.map(\.id)).count, 2)
        XCTAssertEqual(result.effects.count, 2)
        XCTAssertEqual(Set(result.effects.map(\.id)).count, 2)
        XCTAssertEqual(project.clips.count, 1)
    }

    private func fixture() -> DemoProject {
        DemoProject(name: "Clips", recording: VideoRecordingAsset(filename: "primary.mp4", duration: 6,
            width: 1280, height: 720))
    }
}
