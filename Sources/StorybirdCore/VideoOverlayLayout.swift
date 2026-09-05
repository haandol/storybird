import CoreGraphics

public enum VideoOverlayAxis: Sendable {
    case topDown
    case bottomUp
}

public struct VideoOverlayMetrics: Sendable, Equatable {
    public let scale: CGFloat
    public let clickRingDiameter: CGFloat
    public let captionMinimumWidth: CGFloat
    public let captionMaximumWidth: CGFloat
    public let captionGap: CGFloat
    public let edgeInset: CGFloat
    public let subtitleMaximumWidth: CGFloat
    public let subtitleInset: CGFloat
    public let captionFontSize: CGFloat
    public let subtitleFontSize: CGFloat
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let cornerRadius: CGFloat

    /// Scales one overlay design consistently for preview points and exported pixels.
    public init(frameSize: CGSize) {
        scale = max(min(frameSize.width, frameSize.height) / 720, 0.75)
        clickRingDiameter = 48 * scale
        captionMinimumWidth = 96 * scale
        captionMaximumWidth = 260 * scale
        captionGap = 30 * scale
        edgeInset = 8 * scale
        subtitleMaximumWidth = 760 * scale
        subtitleInset = 16 * scale
        captionFontSize = 14 * scale
        subtitleFontSize = 17 * scale
        horizontalPadding = 11 * scale
        verticalPadding = 7 * scale
        cornerRadius = 8 * scale
    }
}

public enum VideoOverlayTiming {
    public static let clickLead: Double = 0.12
    public static let clickTail: Double = 0.55
    public static let captionLead: Double = 1.2
    public static let captionTail: Double = 0.45

    /// Keeps preview and export click animation on the same project-time interval.
    public static func clickIsVisible(
        clickTime: Double,
        at time: Double
    ) -> Bool {
        clickTime - clickLead <= time
            && time <= clickTime + clickTail
    }

    /// Keeps click captions visible for the same lead-in and tail in every renderer.
    public static func captionIsVisible(
        clickTime: Double,
        at time: Double
    ) -> Bool {
        clickTime - captionLead <= time
            && time <= clickTime + captionTail
    }
}

public enum VideoOverlayLayout {
    /// Maps top-left normalized recording coordinates into either renderer coordinate system.
    public static func clickPoint(
        x: Double,
        y: Double,
        in frame: CGRect,
        axis: VideoOverlayAxis
    ) -> CGPoint {
        CGPoint(
            x: frame.minX + CGFloat(x) * frame.width,
            y: axis == .topDown
                ? frame.minY + CGFloat(y) * frame.height
                : frame.minY + (1 - CGFloat(y)) * frame.height
        )
    }

    /// Places a measured click caption beside its point while keeping it inside the video frame.
    public static func captionOrigin(
        labelSize: CGSize,
        x: Double,
        y: Double,
        in frame: CGRect,
        axis: VideoOverlayAxis,
        metrics: VideoOverlayMetrics
    ) -> CGPoint {
        let click = clickPoint(
            x: x,
            y: y,
            in: frame,
            axis: axis
        )
        let desiredX = x <= 0.5
            ? click.x + metrics.captionGap
            : click.x - metrics.captionGap - labelSize.width
        return CGPoint(
            x: min(
                max(desiredX, frame.minX + metrics.edgeInset),
                max(
                    frame.maxX - labelSize.width - metrics.edgeInset,
                    frame.minX + metrics.edgeInset
                )
            ),
            y: min(
                max(
                    click.y - labelSize.height / 2,
                    frame.minY + metrics.edgeInset
                ),
                max(
                    frame.maxY - labelSize.height - metrics.edgeInset,
                    frame.minY + metrics.edgeInset
                )
            )
        )
    }
}
