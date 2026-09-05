import CoreGraphics
import Foundation

public struct VideoNormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct VideoCameraPresentation: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let scale: Double

    public init(x: Double, y: Double, scale: Double) {
        self.x = x
        self.y = y
        self.scale = scale
    }

    public static let identity = VideoCameraPresentation(
        x: 0.5,
        y: 0.5,
        scale: 1
    )

    /// Transforms one normalized content point through the active pan-and-zoom camera.
    public func transform(
        x: Double,
        y: Double
    ) -> VideoNormalizedPoint {
        VideoNormalizedPoint(
            x: 0.5 + (x - self.x) * scale,
            y: 0.5 + (y - self.y) * scale
        )
    }
}

public struct ClickRingPresentation: Equatable, Sendable {
    public let point: VideoNormalizedPoint
    public let diameterScale: Double
    public let opacityScale: Double
}

public enum VideoOverlayPresentation {
    /// Resolves the one active camera state shared by preview and MP4 rendering.
    public static func camera(
        in project: DemoProject,
        at time: Double
    ) -> VideoCameraPresentation {
        guard let effect = project.effects.compactMap({
            if case let .panZoom(value) = $0,
               value.startTime <= time,
               time <= value.endTime {
                return value
            }
            return nil
        }).first else {
            return .identity
        }
        let progress = min(
            max(
                (time - effect.startTime)
                    / max(effect.endTime - effect.startTime, 0.001),
                0
            ),
            1
        )
        return VideoCameraPresentation(
            x: effect.startX
                + (effect.endX - effect.startX) * progress,
            y: effect.startY
                + (effect.endY - effect.startY) * progress,
            scale: effect.startScale
                + (effect.endScale - effect.startScale) * progress
        )
    }

    /// Keeps the click ring attached to the recorded click rather than its description.
    public static func clickPoint(
        for click: TimedPointerClick,
        camera: VideoCameraPresentation
    ) -> VideoNormalizedPoint {
        camera.transform(x: click.x, y: click.y)
    }

    /// Uses custom description coordinates only for the description layer.
    public static func descriptionPoint(
        for click: TimedPointerClick,
        camera: VideoCameraPresentation
    ) -> VideoNormalizedPoint {
        camera.transform(
            x: click.description.position == .custom
                ? click.description.x
                : click.x,
            y: click.description.position == .custom
                ? click.description.y
                : click.y
        )
    }

    /// Produces the same expanding and fading click-ring curve for every renderer.
    public static func clickRing(
        for click: TimedPointerClick,
        at time: Double,
        camera: VideoCameraPresentation
    ) -> ClickRingPresentation {
        let progress = min(
            max(
                (
                    time - click.time
                        + VideoOverlayTiming.clickLead
                ) / (
                    VideoOverlayTiming.clickLead
                        + VideoOverlayTiming.clickTail
                ),
                0
            ),
            1
        )
        return ClickRingPresentation(
            point: clickPoint(for: click, camera: camera),
            diameterScale: 0.65 + 0.7 * progress,
            opacityScale: 1 - progress * 0.85
        )
    }

    /// Scales the persisted font size for the current render frame and content camera.
    public static func fontSize(
        style: TextOverlayStyle,
        metrics: VideoOverlayMetrics,
        contentScale: Double = 1
    ) -> CGFloat {
        CGFloat(style.fontSize)
            * metrics.scale
            * CGFloat(contentScale)
    }

    public static func cardTitleFontSize(
        style: TextOverlayStyle,
        metrics: VideoOverlayMetrics
    ) -> CGFloat {
        max(
            fontSize(style: style, metrics: metrics) * 2,
            24 * metrics.scale
        )
    }

    public static func cardSecondaryFontSize(
        style: TextOverlayStyle,
        metrics: VideoOverlayMetrics
    ) -> CGFloat {
        max(
            fontSize(style: style, metrics: metrics),
            14 * metrics.scale
        )
    }

    /// Reports every layer group that contributes visible pixels at one project time.
    public static func visibleLayerIDs(
        in project: DemoProject,
        at time: Double
    ) -> [UUID] {
        let clickIDs = project.clicks.filter { click in
            let indicatorVisible =
                click.indicator.startTime <= time
                    && time <= click.indicator.endTime
            let descriptionVisible =
                !click.description.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && click.description.startTime <= time
                    && time <= click.description.endTime
            let subtitleVisible =
                !click.cueSubtitle.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && click.cueSubtitle.startTime <= time
                    && time <= click.cueSubtitle.endTime
            return indicatorVisible || descriptionVisible || subtitleVisible
        }.map(\.id)
        let subtitleIDs = project.subtitles.filter {
            !$0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && $0.startTime <= time
                && time <= $0.endTime
        }.map(\.id)
        let effectIDs = project.effects.filter {
            $0.startTime <= time && time <= $0.endTime
        }.map(\.id)
        return clickIDs + subtitleIDs + effectIDs
    }
}
