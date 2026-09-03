import AppKit
import CoreGraphics
@testable import Storybird
import XCTest

@MainActor
final class RecordingHUDLayoutTests: XCTestCase {
    func test_recordingHUDLayout_centersPanelBelowVisibleTop() {
        let origin = RecordingHUDLayout.initialOrigin(
            panelSize: CGSize(width: 330, height: 74),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_440, height: 900)
        )

        XCTAssertEqual(origin.x, 655)
        XCTAssertEqual(origin.y, 780)
    }

    func test_recordingHUDLayout_shortVisibleFrame_keepsPanelInsideBottom() {
        let origin = RecordingHUDLayout.initialOrigin(
            panelSize: CGSize(width: 330, height: 74),
            visibleFrame: CGRect(x: 0, y: 25, width: 1_200, height: 140)
        )

        XCTAssertEqual(origin.x, 435)
        XCTAssertEqual(origin.y, 25)
    }
}
