import XCTest
@testable import StorybirdCore

final class TimelineLayerEditorTests: XCTestCase {
    func test_moveSubtitle_preservesDurationAndFixedTiming() throws {
        let project = fixture()
        let old = try XCTUnwrap(project.subtitles.first)
        let moved = try TimelineLayerEditor.move(.subtitle(old.id), by: 3, in: project)
        var expected = old
        expected.startTime += 3
        expected.endTime += 3
        XCTAssertEqual(moved.subtitles, [expected])
        XCTAssertEqual(moved.clips, project.clips)
        XCTAssertEqual(moved.recording, project.recording)
        XCTAssertEqual(moved.revision, project.revision)
        XCTAssertNil(moved.subtitles[0].sceneAnchor)
    }

    func test_moveSceneSubtitle_reanchorsAcrossClipsAndFollowsNewOwner() throws {
        var project = fixture()
        project.subtitles[0].sceneAnchor = try SceneTiming.anchor(at: 2, in: project)
        let moved = try TimelineLayerEditor.move(.subtitle(project.subtitles[0].id), by: 10, in: project)
        XCTAssertEqual(moved.subtitles[0].sceneAnchor?.clipID, project.clips[1].id)
        let reordered = try VideoTimelineEditor.move(project: moved, clipID: project.clips[1].id, destination: 0)
        XCTAssertEqual(reordered.subtitles[0].startTime, 2, accuracy: 0.000_001)
        XCTAssertEqual(reordered.subtitles[0].endTime, 4, accuracy: 0.000_001)
    }

    func test_moveAudio_preservesSourceRangeGainFadesAndNewSceneOwner() throws {
        var project = fixture()
        project.narrations = [NarrationClip(
            filename: "synthetic.wav", text: "", startTime: 2, duration: 3, volume: 0.5,
            sceneAnchor: try SceneTiming.anchor(at: 2, in: project),
            name: "Audio", sourceStart: 1, sourceDuration: 5, fadeIn: 0.5, fadeOut: 0.5
        )]
        let moved = try TimelineLayerEditor.move(.narration(project.narrations[0].id), by: 10, in: project)
        var expected = project.narrations[0]
        expected.startTime = 12
        expected.sceneAnchor = try SceneTiming.anchor(at: 12, in: project)
        XCTAssertEqual(moved.narrations, [expected])
    }

    func test_moveClick_translatesAllWindowsReanchorsAndRetainsChronologicalOrder() throws {
        var project = try VideoTimelineEditor.addClickCue(to: fixture(), at: 2, x: 0.5, y: 0.5)
        project = try VideoTimelineEditor.addClickCue(to: project, at: 5, x: 0.2, y: 0.2)
        let old = project.clicks[0]
        let moved = try TimelineLayerEditor.move(.click(old.id), by: 10, in: project)
        let click = try XCTUnwrap(moved.clicks.last)
        XCTAssertEqual(moved.clicks.map(\.time), [5, 12])
        XCTAssertEqual(click.id, old.id)
        XCTAssertEqual(click.sourceTime, 12)
        XCTAssertEqual(click.sourceAnchor?.clipID, project.clips[1].id)
        XCTAssertEqual(click.indicator.startTime, old.indicator.startTime + 10)
        XCTAssertEqual(click.indicator.endTime, old.indicator.endTime + 10)
        XCTAssertEqual(click.description.startTime, old.description.startTime + 10)
        XCTAssertEqual(click.description.endTime, old.description.endTime + 10)
        XCTAssertEqual(click.cueSubtitle.startTime, old.cueSubtitle.startTime + 10)
        XCTAssertEqual(click.cueSubtitle.endTime, old.cueSubtitle.endTime + 10)
        XCTAssertEqual(moved.suggestions.first(where: { $0.clickID == old.id })?.splitTime, 12)
        let remapped = VideoTimelineEditor.remapContentLayers(moved)
        XCTAssertEqual(remapped.clicks, moved.clicks)
    }

    func test_moveClick_rejectsOverflowInsteadOfTrimmingWindows() throws {
        let project = try VideoTimelineEditor.addClickCue(to: fixture(), at: 2, x: 0.5, y: 0.5)
        let click = project.clicks[0]
        for delta in [-2.0, 17.9] {
            XCTAssertThrowsError(try TimelineLayerEditor.move(.click(click.id), by: delta, in: project))
        }
    }

    func test_moveLayer_rejectsOutOfProjectMissingAndNonFiniteValues() throws {
        let project = fixture()
        let target = TimelineLayerTarget.subtitle(project.subtitles[0].id)
        for delta in [-2.001, 16.001, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try TimelineLayerEditor.move(target, by: delta, in: project))
        }
        XCTAssertThrowsError(try TimelineLayerEditor.move(.subtitle(UUID()), by: 1, in: project))
        XCTAssertEqual(try TimelineLayerEditor.move(target, by: -2, in: project).subtitles[0].startTime, 0)
        XCTAssertEqual(try TimelineLayerEditor.move(target, by: 16, in: project).subtitles[0].endTime, 20)
    }

    func test_moveSceneLayer_ontoCardIsRejectedWhileFixedSubtitleIsAllowed() throws {
        var project = try DemoEffectEditor.insertTitle(in: fixture(), after: nil, duration: 2, title: "Title")
        let id = project.subtitles[0].id
        let fixed = try TimelineLayerEditor.move(.subtitle(id), by: -3, in: project)
        XCTAssertEqual(fixed.subtitles[0].startTime, 1)
        project.subtitles[0].sceneAnchor = try SceneTiming.anchor(at: 4, in: project)
        XCTAssertThrowsError(try TimelineLayerEditor.move(.subtitle(id), by: -3, in: project))
    }

    func test_moveContentEffect_reanchorsWithoutTrimmingAndRejectsCrossClipRange() throws {
        var project = fixture()
        let effect = DemoEffect.spotlight(SpotlightEffect(
            startTime: 2, endTime: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3
        ))
        project.effects = [VideoTimelineEditor.anchorContentEffect(effect, in: project, at: 2)]
        let moved = try TimelineLayerEditor.move(.effect(effect.id), by: 10, in: project)
        XCTAssertEqual(moved.effects[0].startTime, 12)
        XCTAssertEqual(moved.effects[0].endTime, 14)
        if case let .spotlight(value) = moved.effects[0] {
            XCTAssertEqual(value.sourceAnchor?.clipID, project.clips[1].id)
        } else { XCTFail("Effect kind changed.") }
        XCTAssertEqual(VideoTimelineEditor.remapContentLayers(moved).effects, moved.effects)
        XCTAssertThrowsError(try TimelineLayerEditor.move(.effect(effect.id), by: 7, in: project))
    }

    func test_moveEffect_maintainsExistingSameKindConflictRule() throws {
        var project = fixture()
        project.effects = [
            .spotlight(SpotlightEffect(startTime: 2, endTime: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
            .spotlight(SpotlightEffect(startTime: 6, endTime: 8, x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        ]
        XCTAssertThrowsError(try TimelineLayerEditor.move(.effect(project.effects[0].id), by: 3, in: project))
    }

    func test_moveTitle_preservesCardLengthAndRejectsInvalidPosition() throws {
        let project = try DemoEffectEditor.insertTitle(in: fixture(), after: nil, duration: 2, title: "Title")
        let card = project.effects[0]
        let moved = try TimelineLayerEditor.move(.effect(card.id), by: 10, in: project)
        XCTAssertEqual(moved.effects.first(where: { $0.id == card.id })?.startTime, 10)
        XCTAssertEqual(moved.effects.first(where: { $0.id == card.id })?.endTime, 12)
        XCTAssertEqual(moved.timelineDuration, project.timelineDuration)
        XCTAssertThrowsError(try TimelineLayerEditor.move(.effect(card.id), by: 1, in: project))
        let withCTA = try DemoEffectEditor.insertCTA(in: fixture())
        XCTAssertThrowsError(try TimelineLayerEditor.move(.effect(withCTA.effects[0].id), by: -2, in: withCTA))
    }

    /// Supplies two distinct source-backed scenes and a fixed-time subtitle.
    private func fixture() -> DemoProject {
        DemoProject(
            name: "Synthetic timeline",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 20, width: 1280, height: 720),
            clips: [VideoClip(sourceStart: 0, sourceEnd: 10), VideoClip(sourceStart: 10, sourceEnd: 20)],
            subtitles: [TimedSubtitle(startTime: 2, endTime: 4, text: "Subtitle")]
        )
    }
}
