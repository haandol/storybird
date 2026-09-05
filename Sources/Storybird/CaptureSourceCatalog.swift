import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CaptureWindowFacts: Equatable {
    let isOnScreen: Bool
    let layer: Int
    let frame: CGRect
    let bundleIdentifier: String?
    let applicationName: String?
}

enum CaptureSourceCatalog {
    static let maximumWindowCount = 30
    static let minimumWindowSize = CGSize(width: 220, height: 120)

    static var storybirdBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.storybird.app"
    }

    /// Keeps the human gallery and MCP source list on one eligibility policy.
    static func ordinaryWindows(
        in content: SCShareableContent
    ) -> [SCWindow] {
        content.windows.filter { window in
            isOrdinaryWindow(
                CaptureWindowFacts(
                    isOnScreen: window.isOnScreen,
                    layer: window.windowLayer,
                    frame: window.frame,
                    bundleIdentifier:
                        window.owningApplication?.bundleIdentifier,
                    applicationName:
                        window.owningApplication?.applicationName
                ),
                storybirdBundleIdentifier: storybirdBundleIdentifier
            )
        }
    }

    /// Excludes Storybird-owned processes from full-display capture.
    static func excludedApplications(
        in content: SCShareableContent
    ) -> [SCRunningApplication] {
        content.applications.filter {
            $0.bundleIdentifier == storybirdBundleIdentifier
                || $0.applicationName == "StorybirdMCP"
        }
    }

    /// Applies deterministic source-boundary facts without requiring real SCWindow fixtures.
    static func isOrdinaryWindow(
        _ window: CaptureWindowFacts,
        storybirdBundleIdentifier: String?
    ) -> Bool {
        window.isOnScreen
            && window.layer == 0
            && window.frame.width >= minimumWindowSize.width
            && window.frame.height >= minimumWindowSize.height
            && window.bundleIdentifier != storybirdBundleIdentifier
            && window.applicationName != "StorybirdMCP"
            && window.applicationName != "Window Server"
    }

    static func windowPresentation(
        title: String?,
        applicationName: String?
    ) -> (title: String, applicationName: String) {
        let resolvedApplicationName = applicationName ?? "Application"
        let trimmedTitle = title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return (
            trimmedTitle?.isEmpty == false
                ? trimmedTitle!
                : resolvedApplicationName,
            resolvedApplicationName
        )
    }

    static func displayTitle(
        displayID: CGDirectDisplayID,
        fallbackIndex: Int?
    ) -> String {
        if let title = NSScreen.screens.first(where: {
            screenDisplayID($0) == displayID
        })?.localizedName {
            return title
        }
        if let fallbackIndex {
            return "Display \(fallbackIndex + 1)"
        }
        return "Display"
    }

    private static func screenDisplayID(
        _ screen: NSScreen
    ) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
