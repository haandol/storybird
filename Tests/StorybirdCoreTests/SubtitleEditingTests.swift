import Foundation
import XCTest
@testable import StorybirdCore

final class SubtitleEditingTests: XCTestCase {
    func test_unicodeSplit_preservesGraphemesTextStyleAndSceneBoundary() throws {
        var project = fixture()
        project.clips = [VideoClip(sourceStart: 0, sourceEnd: 2), VideoClip(sourceStart: 2, sourceEnd: 4)]
        let text = "가 e\u{301}👨‍👩‍👧‍👦 나"
        project.subtitles = [TimedSubtitle(startTime: 1, endTime: 3, text: text,
            sceneAnchor: try SceneTiming.anchor(at: 1, in: project))]
        let old = project.subtitles[0]
        let result = try SubtitleEditing.split(old.id, in: project, at: 2, textOffset: 3)
        try VideoProjectValidator.validate(result)
        XCTAssertEqual(result.subtitles.map(\.text), ["가 e\u{301}", "👨‍👩‍👧‍👦 나"])
        XCTAssertEqual(result.subtitles.map(\.text).joined(), text)
        XCTAssertEqual(result.subtitles[0].id, old.id)
        XCTAssertNotEqual(result.subtitles[1].id, old.id)
        XCTAssertEqual(result.subtitles[1].sceneAnchor?.clipID, project.clips[1].id)
        XCTAssertEqual(result.subtitles[1].sceneAnchor?.clipOffset, 0)
        XCTAssertTrue(result.subtitles.allSatisfy { $0.style == old.style && $0.position == old.position })
        for (time, offset) in [(1.0, 3), (3.0, 3), (2.0, 0), (2.0, text.count)] {
            XCTAssertThrowsError(try SubtitleEditing.split(old.id, in: project, at: time, textOffset: offset))
        }
    }

    func test_merge_requiresAdjacentNonoverlappingIndependentCaptionsAndKeepsSuppliedText() throws {
        var project = fixture()
        project.subtitles = [TimedSubtitle(startTime: 0, endTime: 1, text: "A"),
            TimedSubtitle(startTime: 1.5, endTime: 2, text: "B"), TimedSubtitle(startTime: 2, endTime: 3, text: "C")]
        project = try VideoTimelineEditor.addClickCue(to: project, at: 0.5, x: 0.5, y: 0.5)
        let ids = project.subtitles.map(\.id)
        let result = try SubtitleEditing.merge(ids[0], relatedIDs: [ids[1]], text: " Exact combined text ", in: project)
        XCTAssertEqual(result.subtitles.map(\.text), [" Exact combined text ", "C"])
        XCTAssertEqual(result.subtitles[0].startTime, 0)
        XCTAssertEqual(result.subtitles[0].endTime, 2)
        XCTAssertEqual(result.clicks, project.clicks)
        XCTAssertThrowsError(try SubtitleEditing.merge(ids[0], relatedIDs: [ids[2]], text: "No gap in selection", in: project))
        XCTAssertThrowsError(try SubtitleEditing.merge(ids[0], relatedIDs: [project.clicks[0].id], text: "No Cue conversion", in: project))
        project.subtitles[1].startTime = 0.9
        XCTAssertThrowsError(try SubtitleEditing.merge(ids[0], relatedIDs: [ids[1]], text: "Overlap", in: project))
    }

    func test_subtitleSplitMerge_invalidTextPrimaryAndCardAnchorPreserveInput() throws {
        var project = fixture()
        project.clips = [VideoClip(sourceStart: 0, sourceEnd: 2), VideoClip(sourceStart: 2, sourceEnd: 4)]
        project = try DemoEffectEditor.insertTitle(in: project, after: project.clips[0].id, duration: 1)
        project.subtitles = [TimedSubtitle(startTime: 1, endTime: 4, text: "First second",
            sceneAnchor: try SceneTiming.anchor(at: 1, in: project))]
        let before = project
        XCTAssertThrowsError(try SubtitleEditing.split(project.subtitles[0].id, in: project, at: 2.5, textOffset: 5))
        XCTAssertEqual(project, before)
        project.subtitles[0].text = "  A B"
        XCTAssertThrowsError(try SubtitleEditing.split(project.subtitles[0].id, in: project, at: 1.5, textOffset: 1))
        XCTAssertThrowsError(try SubtitleEditing.split(project.subtitles[0].id, in: project, at: .nan, textOffset: 3))
        project.subtitles = [TimedSubtitle(startTime: 0, endTime: 1, text: "First"), TimedSubtitle(startTime: 1, endTime: 2, text: "Second")]
        let first = project.subtitles[0].id, second = project.subtitles[1].id
        let original = project
        XCTAssertThrowsError(try SubtitleEditing.merge(second, relatedIDs: [first], text: "Combined", in: project))
        XCTAssertThrowsError(try SubtitleEditing.merge(first, relatedIDs: [first], text: "Repeated ID", in: project))
        XCTAssertThrowsError(try SubtitleEditing.merge(first, relatedIDs: [second], text: " \n", in: project))
        XCTAssertEqual(project, original)
    }

    func test_srtUTF8CRLFAndBOM_preserveTextAndRejectMalformedInput() throws {
        let data = Data("\u{FEFF}5\r\n00:00:00,100 --> 00:00:01,250\r\n한글 e\u{301}\r\nSecond line\r\n\r\n9\r\n00:00:02,000 --> 00:00:03,000\r\n👨‍👩‍👧‍👦\r\n".utf8)
        let rows = try SRTCaptions.parse(data)
        XCTAssertEqual(rows.map(\.text), ["한글 e\u{301}\nSecond line", "👨‍👩‍👧‍👦"])
        XCTAssertEqual(rows[0].startTime, 0.1)
        XCTAssertEqual(rows[0].endTime, 1.25)
        XCTAssertTrue(rows.allSatisfy { $0.sceneAnchor == nil })
        for bad in [Data([0xFF]), Data("".utf8), Data("1\n00:00:60,000 --> 00:01:01,000\nWrong".utf8),
            Data("1\n00:00:02,000 --> 00:00:01,000\nBackwards".utf8)] {
            XCTAssertThrowsError(try SRTCaptions.parse(bad))
        }
    }

    func test_srtOrderingScopeAndHalfUpRounding_areStableWithoutMutation() throws {
        var project = fixture()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        project.subtitles = [TimedSubtitle(id: second, startTime: 1.0005, endTime: 1.0025, text: "Second ID"),
            TimedSubtitle(id: first, startTime: 1.0005, endTime: 1.0025, text: "First ID")]
        var cue = TimedPointerClick(time: 1.001, x: 0.5, y: 0.5)
        cue.cueSubtitle = CueSubtitle(text: "Cue", startTime: 1.0005, endTime: 1.0025)
        project.clicks = [cue]
        let before = project
        let output = try SRTCaptions.encode(project: project, scope: .both)
        XCTAssertEqual(output, "1\n00:00:01,001 --> 00:00:01,003\nFirst ID\n\n2\n00:00:01,001 --> 00:00:01,003\nSecond ID\n\n3\n00:00:01,001 --> 00:00:01,003\nCue\n")
        XCTAssertEqual(try SRTCaptions.encode(project: project, scope: .both), output)
        XCTAssertFalse(try SRTCaptions.encode(project: project, scope: .independent).contains("Cue"))
        XCTAssertFalse(try SRTCaptions.encode(project: project, scope: .cue).contains("ID"))
        XCTAssertEqual(project, before)
    }

    func test_srtCollapsedIntervalOrBlankParagraph_failsWithoutChangingText() throws {
        var project = fixture()
        project.subtitles = [TimedSubtitle(startTime: 0.0001, endTime: 0.0004, text: "Tiny")]
        XCTAssertThrowsError(try SRTCaptions.encode(project: project, scope: .independent))
        project.subtitles[0].endTime = 1
        project.subtitles[0].text = "Paragraph\n\nTwo"
        XCTAssertThrowsError(try SRTCaptions.encode(project: project, scope: .independent))
        XCTAssertEqual(project.subtitles[0].text, "Paragraph\n\nTwo")
    }

    private func fixture() -> DemoProject {
        DemoProject(name: "Captions", recording: VideoRecordingAsset(filename: "video.mp4", duration: 4, width: 1280, height: 720))
    }
}
