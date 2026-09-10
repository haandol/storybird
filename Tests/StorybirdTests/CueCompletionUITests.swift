import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class CueCompletionUITests: XCTestCase {
    func test_exportAvailability_requiresBothNonblankSlotsAndValidProject() throws {
        var project = try fixture()
        XCTAssertFalse(VideoExportAvailability.isReady(nil))
        XCTAssertFalse(VideoExportAvailability.isReady(project))
        project.clicks[0].description.text = "Description"
        project.clicks[0].cueSubtitle.text = " \n "
        XCTAssertFalse(VideoExportAvailability.isReady(project))
        project.clicks[0].cueSubtitle.text = "Subtitle"
        XCTAssertTrue(VideoExportAvailability.isReady(project))
        project.clicks[0].indicator.endTime = 0.5
        XCTAssertFalse(VideoExportAvailability.isReady(project))
    }

    func test_nativeMenu_listsMissingSlotsAndSelectsTheCorrectCue() async throws {
        var project = try fixture()
        project = try VideoTimelineEditor.addClickCue(to: project, at: 2, x: 0.2, y: 0.2)
        project.clicks[1].description.text = "Description"
        project = try VideoTimelineEditor.addClickCue(to: project, at: 3, x: 0.8, y: 0.8)
        project.clicks[2].description.text = "Complete"
        project.clicks[2].cueSubtitle.text = "Complete"
        let original = project
        var selected: UUID?
        let view = NSHostingView(rootView: ClickCueReviewMenu(clicks: project.clicks) { selected = $0 }
            .frame(width: 400, height: 80))
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 400, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let popup = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertTrue(popup.title.contains("2 incomplete"), popup.title)
        XCTAssertNotNil(popup.menu)
        // Popup tracking runs a nested event loop that does not drain the main
        // dispatch queue. Inspect and close it using that loop's timer mode.
        let inspection = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let activeMenu = popup.menu else { return XCTFail("Missing popup menu.") }
                defer { activeMenu.cancelTracking() }
                let items = activeMenu.items.filter { $0.title.contains("Missing") }
                XCTAssertEqual(items.count, 2, "\(activeMenu.items.map(\.title))")
                XCTAssertTrue(items.contains { $0.title.contains("1.00s") && $0.title.contains("description and subtitle") })
                XCTAssertTrue(items.contains { $0.title.contains("2.00s") && $0.title.contains("Missing subtitle") })
                if let target = activeMenu.items.firstIndex(where: { $0.title.contains("2.00s") }) {
                    activeMenu.performActionForItem(at: target)
                }
            }
        }
        RunLoop.main.add(inspection, forMode: .eventTracking)
        RunLoop.main.add(inspection, forMode: .common)
        popup.performClick(nil)
        inspection.invalidate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(selected, project.clicks[1].id)
        XCTAssertEqual(project, original, "Reviewing completeness must not mutate project data.")
    }

    /// Builds only valid in-memory Cue data; no actual recording is opened.
    private func fixture() throws -> DemoProject {
        let project = DemoProject(name: "Cue review",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 4, width: 640, height: 480))
        return try VideoTimelineEditor.addClickCue(to: project, at: 1, x: 0.5, y: 0.5)
    }

    /// Limits native inspection to the isolated menu fixture.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
