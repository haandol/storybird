import StorybirdCore
import XCTest
@testable import Storybird

final class TimelineTrackLayoutTests: XCTestCase {
    func test_automaticRows_sequentialAndTouchingSubtitlesShareOneRow() {
        let project = fixture()
        let rows = TimelineTrackLayout.rows(in: project).filter { $0.kind == .subtitle }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].spans.map(\.id), project.subtitles.map(\.id))
        XCTAssertEqual(rows[0].groupCount, 6)
        XCTAssertTrue(rows[0].isGroupHeader)
    }

    func test_automaticRows_subMillisecondTouchingLayersDoNotAcquireFalseOverlap() {
        var project = fixture()
        project.subtitles = [
            TimedSubtitle(startTime: 2, endTime: 2.0005, text: "A"),
            TimedSubtitle(startTime: 2.0005, endTime: 2.001, text: "B")
        ]
        let rows = TimelineTrackLayout.rows(in: project).filter { $0.kind == .subtitle }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.spans.first?.end, 2.0005)
    }

    func test_automaticRows_overlapUsesOnlyNecessaryLanesAndRetainsEveryLayer() {
        let spans = [span(0, 8), span(0, 2), span(1, 3), span(2, 4), span(4, 8), span(8, 10)]
        let rows = TimelineTrackLayout.packedRows(spans)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.flatMap { $0 }.map(\.id)), Set(spans.map(\.id)))
        for row in rows {
            for pair in zip(row, row.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
            }
        }
        XCTAssertEqual(rows[0].last?.id, spans.last?.id)
    }

    func test_automaticRows_sortsUnorderedStartsAndKeepsEqualStartsStable() {
        let spans = [span(6, 8), span(2, 4), span(2, 3), span(0, 2)]
        let rows = TimelineTrackLayout.packedRows(spans)
        XCTAssertEqual(rows[0].map(\.id), [spans[3].id, spans[1].id, spans[0].id])
        XCTAssertEqual(rows[1].map(\.id), [spans[2].id])
    }

    func test_expansion_affectsOnlySelectedKindAndDoesNotChangeProject() {
        var project = fixture()
        project.narrations = (0..<3).map {
            NarrationClip(filename: "audio-\($0).wav", text: "", startTime: Double($0 * 2), duration: 2)
        }
        let original = project
        let compact = TimelineTrackLayout.rows(in: project)
        let expanded = TimelineTrackLayout.rows(in: project, expandedKinds: [.subtitle])
        XCTAssertEqual(compact.filter { $0.kind == .narration }.count, 1)
        XCTAssertEqual(expanded.filter { $0.kind == .narration }.count, 1)
        XCTAssertEqual(expanded.filter { $0.kind == .subtitle }.count, 6)
        XCTAssertTrue(expanded.filter { $0.kind == .subtitle }.allSatisfy { $0.spans.count == 1 })
        XCTAssertEqual(expanded.filter { $0.kind == .subtitle && $0.isGroupHeader }.count, 1)
        XCTAssertEqual(Set(expanded.map(\.id)).count, expanded.count)
        XCTAssertEqual(project, original)
    }

    func test_automaticRows_audioClicksAndEffectsUseSamePackingRule() {
        var project = fixture()
        project.narrations = (0..<2).map {
            NarrationClip(filename: "audio-\($0).wav", text: "", startTime: Double($0 * 3), duration: 2)
        }
        project.clicks = [TimedPointerClick(time: 2, x: 0.5, y: 0.5), TimedPointerClick(time: 8, x: 0.5, y: 0.5)]
        project.effects = [
            .spotlight(SpotlightEffect(startTime: 0, endTime: 2, x: 0, y: 0, width: 0.5, height: 0.5)),
            .panZoom(PanZoomEffect(startTime: 2, endTime: 4, endX: 0.5, endY: 0.5, endScale: 2))
        ]
        for kind in [TimelineTrack.Kind.click, .narration, .effect] {
            XCTAssertEqual(TimelineTrackLayout.rows(in: project).filter { $0.kind == kind }.count, 1)
            XCTAssertEqual(TimelineTrackLayout.rows(in: project, expandedKinds: [kind]).filter { $0.kind == kind }.count, 2)
        }
    }

    func test_emptyKinds_keepOneHeaderAndNoPhantomBlocks() {
        var project = fixture()
        project.subtitles = []
        for row in TimelineTrackLayout.rows(in: project) where row.kind.supportsExpansion {
            XCTAssertTrue(row.isGroupHeader)
            XCTAssertEqual(row.groupCount, 0)
            XCTAssertTrue(row.spans.isEmpty)
        }
        XCTAssertTrue(TimelineTrackLayout.packedRows([]).isEmpty)
    }

    func test_packing_matchesPeakConcurrencyAcrossDeterministicIntervalSets() {
        for seed in 0..<40 {
            let spans = (0..<30).map { index in
                let start = Double((index * 17 + seed * 7) % 50)
                return span(start, start + Double(1 + (index * 11 + seed) % 8))
            }
            let peak = spans.map { point in
                spans.filter { $0.start <= point.start && point.start < $0.end }.count
            }.max()!
            let rows = TimelineTrackLayout.packedRows(spans)
            XCTAssertEqual(rows.count, peak)
            XCTAssertEqual(rows.flatMap { $0 }.count, spans.count)
            for row in rows {
                for pair in zip(row, row.dropFirst()) {
                    XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
                }
            }
        }
    }

    /// Produces explicit half-open intervals independently of project validation.
    private func span(_ start: Double, _ end: Double) -> TimelineTrackSpan {
        TimelineTrackSpan(id: UUID(), start: start, end: end)
    }

    /// Uses six adjacent subtitle intervals so the two view modes visibly differ.
    private func fixture() -> DemoProject {
        DemoProject(
            name: "Synthetic rows",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 20, width: 1280, height: 720),
            subtitles: (0..<6).map {
                TimedSubtitle(startTime: Double($0 * 2), endTime: Double($0 * 2 + 2), text: "Subtitle \($0)")
            }
        )
    }
}
