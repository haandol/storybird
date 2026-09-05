import CoreGraphics
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
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

    func test_timedClickIngress_mapsQuartzPointToVideoTimeline() throws {
        let ingress = TimedClickIngress()
        ingress.start()

        let accepted = ingress.accept(
            screenPoint: CGPoint(x: 500, y: 250),
            captureFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            time: 1.25,
            button: .right
        )

        let click = try XCTUnwrap(ingress.acceptedClicks().first)
        XCTAssertTrue(accepted)
        XCTAssertEqual(click.time, 1.25, accuracy: 0.001)
        XCTAssertEqual(click.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(click.y, 0.25, accuracy: 0.001)
        XCTAssertEqual(click.button, .right)
    }

    func test_timedClickIngress_preservesOrderAndRejectsAfterStop() {
        let ingress = TimedClickIngress()
        ingress.start()

        XCTAssertTrue(
            ingress.accept(
                screenPoint: CGPoint(x: 10, y: 10),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                time: 0.5,
                button: .left
            )
        )
        XCTAssertTrue(
            ingress.accept(
                screenPoint: CGPoint(x: 20, y: 20),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                time: 0.75,
                button: .right
            )
        )

        ingress.stopAccepting()

        XCTAssertFalse(
            ingress.accept(
                screenPoint: CGPoint(x: 30, y: 30),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                time: 1,
                button: .left
            )
        )
        let clicks = ingress.acceptedClicks()
        XCTAssertEqual(clicks.map(\.time), [0.5, 0.75])
        XCTAssertEqual(clicks.map(\.x), [0.1, 0.2])
        XCTAssertEqual(clicks.map(\.button), [.left, .right])
    }

    func test_captureSourceCatalog_acceptsOrdinaryWindowAtMinimumSize() {
        let window = CaptureWindowFacts(
            isOnScreen: true,
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 220, height: 120),
            bundleIdentifier: "com.example.target",
            applicationName: "Target"
        )

        XCTAssertTrue(
            CaptureSourceCatalog.isOrdinaryWindow(
                window,
                storybirdBundleIdentifier: "com.storybird.app"
            )
        )
    }

    func test_captureSourceCatalog_rejectsSystemSelfAndUtilityWindows() {
        let ordinary = CaptureWindowFacts(
            isOnScreen: true,
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 220, height: 120),
            bundleIdentifier: "com.example.target",
            applicationName: "Target"
        )
        let rejected = [
            CaptureWindowFacts(
                isOnScreen: false,
                layer: ordinary.layer,
                frame: ordinary.frame,
                bundleIdentifier: ordinary.bundleIdentifier,
                applicationName: ordinary.applicationName
            ),
            CaptureWindowFacts(
                isOnScreen: ordinary.isOnScreen,
                layer: 1,
                frame: ordinary.frame,
                bundleIdentifier: ordinary.bundleIdentifier,
                applicationName: ordinary.applicationName
            ),
            CaptureWindowFacts(
                isOnScreen: ordinary.isOnScreen,
                layer: ordinary.layer,
                frame: CGRect(x: 0, y: 0, width: 219, height: 120),
                bundleIdentifier: ordinary.bundleIdentifier,
                applicationName: ordinary.applicationName
            ),
            CaptureWindowFacts(
                isOnScreen: ordinary.isOnScreen,
                layer: ordinary.layer,
                frame: ordinary.frame,
                bundleIdentifier: "com.storybird.app",
                applicationName: "Storybird"
            ),
            CaptureWindowFacts(
                isOnScreen: ordinary.isOnScreen,
                layer: ordinary.layer,
                frame: ordinary.frame,
                bundleIdentifier: nil,
                applicationName: "StorybirdMCP"
            ),
            CaptureWindowFacts(
                isOnScreen: ordinary.isOnScreen,
                layer: ordinary.layer,
                frame: ordinary.frame,
                bundleIdentifier: nil,
                applicationName: "Window Server"
            ),
        ]

        for window in rejected {
            XCTAssertFalse(
                CaptureSourceCatalog.isOrdinaryWindow(
                    window,
                    storybirdBundleIdentifier: "com.storybird.app"
                )
            )
        }
    }

    func test_captureSourceCatalog_usesTrimmedTitleOrApplicationFallback() {
        XCTAssertEqual(
            CaptureSourceCatalog.windowPresentation(
                title: "  Demo Window  ",
                applicationName: "Demo App"
            ).title,
            "Demo Window"
        )
        XCTAssertEqual(
            CaptureSourceCatalog.windowPresentation(
                title: "   ",
                applicationName: "Demo App"
            ).title,
            "Demo App"
        )
        XCTAssertEqual(CaptureSourceCatalog.maximumWindowCount, 30)
    }
}
