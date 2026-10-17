import Foundation
import XCTest
@testable import StorybirdCore

final class ProjectEditPlannerTests: XCTestCase {
    func test_clipGroupMoves_preserveRelativeOrderAndRemapOwnedCaptionOnce() throws {
        var project = fixture()
        project.clips = (0..<5).map { VideoClip(sourceStart: Double($0), sourceEnd: Double($0 + 1)) }
        project.subtitles = [TimedSubtitle(startTime: 1.5, endTime: 1.9, text: "Owned",
            sceneAnchor: try SceneTiming.anchor(at: 1.5, in: project))]
        let ids = project.clips.map(\.id)
        for (destination, order, start) in [(0, [1, 3, 0, 2, 4], 0.5), (3, [0, 2, 4, 1, 3], 3.5)] {
            let edits = try ProjectEditPlanner.moveClips([ids[1], ids[3]], to: destination, in: project)
            XCTAssertEqual(edits.count, 2)
            let result = try ProjectEditPlanner.plan(edits, in: project)
            XCTAssertEqual(result.project.clips.map(\.id), order.map { ids[$0] })
            XCTAssertEqual(result.project.subtitles[0].startTime, start)
            XCTAssertEqual(result.project.subtitles[0].endTime - result.project.subtitles[0].startTime, 0.4, accuracy: 0.000001)
        }
        XCTAssertThrowsError(try ProjectEditPlanner.moveClips([ids[1], ids[3]], to: 4, in: project))
    }

    func test_finalValidation_allowsFixedAudioToMoveInsideShortenedTimelineTogether() throws {
        var project = fixture()
        project.narrations = [NarrationClip(filename: "a.wav", text: "A", startTime: 4, duration: 1),
            NarrationClip(filename: "b.wav", text: "B", startTime: 5, duration: 1)]
        let edits = [ProjectEdit(target: .clip, id: project.clips[0].id, action: .update, values: ["source_end": .number(4)])]
            + project.narrations.map { ProjectEdit(target: .audio, id: $0.id, action: .move, values: ["delta": .number(-2)]) }
        let result = try ProjectEditPlanner.plan(edits, in: project)
        XCTAssertEqual(result.project.timelineDuration, 4)
        XCTAssertEqual(result.project.narrations.map(\.startTime), [2, 3])
        XCTAssertEqual(result.project.narrations.map(\.assetID), project.narrations.map(\.assetID))
        XCTAssertThrowsError(try ProjectEditPlanner.plan(Array(edits.prefix(2)), in: project))
    }

    func test_finalValidation_allowsSwappingEffectsThatTemporarilyOverlap() throws {
        var project = fixture()
        project.effects = [
            .spotlight(SpotlightEffect(startTime: 1, endTime: 2, x: 0, y: 0, width: 0.2, height: 0.2)),
            .spotlight(SpotlightEffect(startTime: 3, endTime: 4, x: 0.5, y: 0.5, width: 0.2, height: 0.2)),
        ]
        let edits = [ProjectEdit(target: .effect, id: project.effects[0].id, action: .update,
            values: ["start_time": .number(3), "end_time": .number(4)]),
            ProjectEdit(target: .effect, id: project.effects[1].id, action: .update,
            values: ["start_time": .number(1), "end_time": .number(2)])]
        let planned = try ProjectEditPlanner.plan(edits, in: project)
        XCTAssertEqual(planned.project.effects.map(\.startTime), [3, 1])
        XCTAssertEqual(planned.direct.count, 2)
        XCTAssertThrowsError(try ProjectEditPlanner.plan([edits[0]], in: project))
    }

    func test_selectedClipAndOwnedCaption_deleteOnceAndRejectConflictingSplitRetiming() throws {
        var project = fixture()
        let clip = project.clips[0]
        project.subtitles = [TimedSubtitle(startTime: 1, endTime: 2, text: "Linked",
            sceneAnchor: try SceneTiming.anchor(at: 1, in: project))]
        let subtitle = project.subtitles[0]
        let deleted = try ProjectEditPlanner.plan([
            ProjectEdit(target: .clip, id: clip.id, action: .delete),
            ProjectEdit(target: .subtitle, id: subtitle.id, action: .delete),
        ], in: project)
        XCTAssertTrue(deleted.project.clips.isEmpty)
        XCTAssertTrue(deleted.project.subtitles.isEmpty)
        XCTAssertEqual(deleted.direct.count, 2)
        XCTAssertThrowsError(try ProjectEditPlanner.plan([
            ProjectEdit(target: .clip, id: clip.id, action: .split, values: ["source_time": .number(3)]),
            ProjectEdit(target: .subtitle, id: subtitle.id, action: .update, values: ["start_time": .number(1.5)]),
        ], in: project)) { XCTAssertEqual(($0 as? ProjectEditError)?.code, "conflicting_timing") }
        let styled = try ProjectEditPlanner.plan([
            ProjectEdit(target: .clip, id: clip.id, action: .split, values: ["source_time": .number(3)]),
            ProjectEdit(target: .subtitle, id: subtitle.id, action: .update, values: ["font_size": .number(24)]),
        ], in: project)
        XCTAssertEqual(styled.project.subtitles[0].startTime, 1)
        XCTAssertEqual(styled.project.subtitles[0].style.fontSize, 24)
    }

    func test_duplicateCue_preservesExistingPendingSuggestionEdits() throws {
        var project = try VideoTimelineEditor.addClickCue(to: fixture(), at: 1, x: 0.5, y: 0.5)
        project.suggestions[0].splitTime = 1.1
        project.suggestions[0].spotlight.width = 0.3
        let original = project.suggestions[0]
        let result = try ProjectEditPlanner.plan([ProjectEdit(target: .click, id: project.clicks[0].id,
            action: .duplicate, values: ["start_time": .number(3)])], in: project)
        XCTAssertEqual(result.project.suggestions.first { $0.id == original.id }, original)
        XCTAssertEqual(result.project.suggestions.count, 2)
        XCTAssertEqual(result.project.clicks.count, 2)
    }

    func test_snapping_usesDistanceKindEarlierTimeAndTemporaryBypass() {
        let playhead = TimelineSnapCandidate(time: 2, kind: .playhead)
        let clip = TimelineSnapCandidate(time: 1, kind: .clipBoundary)
        let layer = TimelineSnapCandidate(time: 1, kind: .layerBoundary)
        XCTAssertEqual(TimelineSnapping.nearest(to: 1.5, tolerance: 0.5, candidates: [layer, clip, playhead]), playhead)
        XCTAssertEqual(TimelineSnapping.nearest(to: 1.5, tolerance: 0.5, candidates: [layer, clip]), clip)
        XCTAssertEqual(TimelineSnapping.nearest(to: 1.5, tolerance: 0.5,
            candidates: [TimelineSnapCandidate(time: 2, kind: .clipBoundary), clip]), clip)
        XCTAssertNil(TimelineSnapping.nearest(to: 1.5, tolerance: 0.49, candidates: [clip]))
        XCTAssertNil(TimelineSnapping.nearest(to: 1.5, tolerance: 0.5, candidates: [clip], bypass: true))
    }

    private func fixture() -> DemoProject {
        DemoProject(name: "Plan", recording: VideoRecordingAsset(filename: "source.mp4", duration: 6,
            width: 1280, height: 720))
    }
}
