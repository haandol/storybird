import CoreGraphics
import ScreenCaptureKit
import StorybirdCore

enum ScreenCaptureFrameResolver {
    /// Resolves a live source frame when sample metadata cannot provide one.
    static func fallbackFrame(
        filter: SCContentFilter,
        windowID: CGWindowID?,
        initialCaptureFrame: CGRect
    ) -> CGRect {
        var liveFrame = windowID.flatMap(
            CaptureFrameGeometry.currentWindowFrame(windowID:)
        )
        if #available(macOS 15.2, *) {
            if filter.style == .window,
               let window = filter.includedWindows.first {
                liveFrame = window.frame
            }
            if filter.style == .display,
               let display = filter.includedDisplays.first {
                liveFrame = display.frame
            }
        }
        let fallback = initialCaptureFrame.width > 0
            && initialCaptureFrame.height > 0
            ? initialCaptureFrame
            : filter.contentRect
        return CaptureFrameGeometry.preferredFrame(
            sampleFrame: nil,
            liveWindowFrame: liveFrame,
            fallbackFrame: fallback
        )
    }
}
