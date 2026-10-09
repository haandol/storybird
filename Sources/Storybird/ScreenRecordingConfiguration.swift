import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Keeps native and MCP recording streams on the same silent, cursor-visible settings.
enum ScreenRecordingConfiguration {
    static func make(
        filter: SCContentFilter,
        fallbackCaptureFrame: CGRect,
        isWindow: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let contentRect = filter.contentRect.width > 0
            && filter.contentRect.height > 0
            ? filter.contentRect
            : fallbackCaptureFrame
        configuration.width = max(
            Int(contentRect.width * CGFloat(filter.pointPixelScale)),
            2
        )
        configuration.height = max(
            Int(contentRect.height * CGFloat(filter.pointPixelScale)),
            2
        )
        // Request up to 60 fps; 15 fps visibly stepped sliders and drags in recorded demos.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = isWindow
        return configuration
    }
}
