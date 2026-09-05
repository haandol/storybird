import CoreGraphics
import Foundation

public enum CaptureFrameGeometry {
    /// Reads a window's current Quartz bounds without activating that window.
    public static func currentWindowFrame(
        windowID: CGWindowID
    ) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[CFString: Any]],
            let bounds = windows.first?[kCGWindowBounds] as? NSDictionary
        else {
            return nil
        }
        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(
            bounds,
            &frame
        ) else {
            return nil
        }
        return frame
    }

    /// Chooses the frame that corresponds most closely to the captured pixels.
    ///
    /// ScreenCaptureKit's per-frame onscreen rectangle wins, followed by a
    /// live window lookup, with the source-selection frame used only when the
    /// runtime cannot provide a current location.
    public static func preferredFrame(
        sampleFrame: CGRect?,
        liveWindowFrame: CGRect?,
        fallbackFrame: CGRect
    ) -> CGRect {
        if let sampleFrame, isUsable(sampleFrame) {
            return sampleFrame
        }
        if let liveWindowFrame, isUsable(liveWindowFrame) {
            return liveWindowFrame
        }
        return fallbackFrame
    }

    /// Rejects empty or non-finite rectangles before coordinate normalization.
    private static func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
    }
}
