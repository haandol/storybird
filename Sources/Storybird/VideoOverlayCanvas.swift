import StorybirdCore
import SwiftUI

struct VideoOverlayCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect
    var camera: VideoCameraPresentation = .identity

    var body: some View {
        let metrics = VideoOverlayMetrics(frameSize: imageFrame.size, renderSize: project.overlayRenderSize)
        ZStack(alignment: .topLeading) {
            ForEach(project.clicks.filter {
                $0.indicator.startTime <= time
                    && time <= $0.indicator.endTime
            }) { click in
                let presentation = VideoOverlayPresentation.clickRing(
                    for: click,
                    at: time,
                    camera: camera
                )
                let point = VideoOverlayLayout.clickPoint(
                    x: presentation.point.x,
                    y: presentation.point.y,
                    in: imageFrame,
                    axis: .topDown
                )
                Circle()
                    .fill(Color(hex: click.indicator.colorHex).opacity(0.18))
                    .overlay(
                        Circle()
                            .stroke(
                                Color(hex: click.indicator.colorHex),
                                lineWidth: 3 * camera.scale
                            )
                    )
                    .frame(
                        width: metrics.clickRingDiameter * click.indicator.size
                            * CGFloat(presentation.diameterScale * camera.scale),
                        height: metrics.clickRingDiameter * click.indicator.size
                            * CGFloat(presentation.diameterScale * camera.scale)
                    )
                    .opacity(
                        click.indicator.opacity
                            * presentation.opacityScale
                    )
                    .position(point)
            }

            ForEach(project.clicks.filter {
                !$0.caption.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && $0.description.startTime <= time
                    && time <= $0.description.endTime
            }) { click in
                VideoClickCaptionOverlay(
                    click: click,
                    imageFrame: imageFrame,
                    metrics: metrics,
                    camera: camera
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private extension DemoProject {
    /// Exported frames are rendered at the recording size.
    var overlayRenderSize: CGSize? {
        recording.map { CGSize(width: $0.width, height: $0.height) }
    }
}

struct VideoScreenOverlayCanvas: View {
    let project: DemoProject
    let time: Double
    let imageFrame: CGRect

    var body: some View {
        let metrics = VideoOverlayMetrics(frameSize: imageFrame.size, renderSize: project.overlayRenderSize)
        ZStack {
            ForEach(project.subtitles.filter {
                $0.startTime <= time && time <= $0.endTime
            }) { subtitle in
                VideoSubtitleOverlay(
                    subtitle: subtitle,
                    imageFrame: imageFrame,
                    metrics: metrics
                )
            }
            ForEach(project.clicks.filter {
                $0.cueSubtitle.startTime <= time
                    && time <= $0.cueSubtitle.endTime
                    && !$0.cueSubtitle.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }) { click in
                VideoSubtitleOverlay(
                    subtitle: TimedSubtitle(
                        id: click.id,
                        startTime: click.cueSubtitle.startTime,
                        endTime: click.cueSubtitle.endTime,
                        text: click.cueSubtitle.text,
                        position: click.cueSubtitle.position,
                        style: click.cueSubtitle.style
                    ),
                    imageFrame: imageFrame,
                    metrics: metrics
                )
            }
            ForEach(activeEffects) { effect in
                switch effect {
                case let .spotlight(value):
                    SpotlightShape(value: value, frame: imageFrame)
                        .fill(
                            Color.black.opacity(value.dimOpacity),
                            style: FillStyle(eoFill: true)
                        )
                case let .title(value):
                    card(
                        title: value.title,
                        secondary: value.subtitle,
                        style: value.style,
                        metrics: metrics
                    )
                case let .cta(value):
                    card(
                        title: value.title,
                        secondary: value.buttonLabel,
                        style: value.style,
                        metrics: metrics
                    )
                case .panZoom:
                    EmptyView()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var activeEffects: [DemoEffect] {
        project.effects.filter {
            $0.startTime <= time && time <= $0.endTime
        }
    }

    private func card(
        title: String,
        secondary: String,
        style: TextOverlayStyle,
        metrics: VideoOverlayMetrics
    ) -> some View {
        ZStack {
            Color(hex: style.backgroundHex)
                .opacity(style.backgroundOpacity)
            VStack(spacing: 12) {
                Text(title)
                    .font(
                        .system(
                            size: VideoOverlayPresentation
                                .cardTitleFontSize(
                                    style: style,
                                    metrics: metrics
                                ),
                            weight: .bold
                        )
                    )
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(
                            .system(
                                size: VideoOverlayPresentation
                                    .cardSecondaryFontSize(
                                        style: style,
                                        metrics: metrics
                                    ),
                                weight: .semibold
                            )
                        )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Color(hex: style.foregroundHex)
                                .opacity(0.15),
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(Color(hex: style.foregroundHex))
        }
        .frame(width: imageFrame.width, height: imageFrame.height)
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }
}

private struct SpotlightShape: Shape {
    let value: SpotlightEffect
    let frame: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(frame)
        path.addRoundedRect(
            in: CGRect(
                x: frame.minX + CGFloat(value.x) * frame.width,
                y: frame.minY + CGFloat(value.y) * frame.height,
                width: CGFloat(value.width) * frame.width,
                height: CGFloat(value.height) * frame.height
            ),
            cornerSize: CGSize(width: 10, height: 10)
        )
        return path
    }
}

private struct VideoSubtitleOverlay: View {
    let subtitle: TimedSubtitle
    let imageFrame: CGRect
    let metrics: VideoOverlayMetrics

    var body: some View {
        VStack {
            if subtitle.position == .bottom {
                Spacer(minLength: 0)
            }
            VideoOverlayLabel(
                text: subtitle.text,
                style: subtitle.style,
                fontSize: VideoOverlayPresentation.fontSize(
                    style: subtitle.style,
                    metrics: metrics
                ),
                metrics: metrics
            )
            .frame(
                maxWidth: min(
                    metrics.subtitleMaximumWidth,
                    imageFrame.width - metrics.subtitleInset * 2
                )
            )
            if subtitle.position == .top {
                Spacer(minLength: 0)
            }
        }
        .frame(
            width: max(
                imageFrame.width - metrics.subtitleInset * 2,
                0
            ),
            height: max(
                imageFrame.height - metrics.subtitleInset * 2,
                0
            )
        )
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }
}

private struct VideoClickCaptionOverlay: View {
    let click: TimedPointerClick
    let imageFrame: CGRect
    let metrics: VideoOverlayMetrics
    let camera: VideoCameraPresentation
    @State private var labelSize = CGSize(
        width: 1,
        height: 1
    )

    var body: some View {
        let width = min(
            max(metrics.captionMinimumWidth, imageFrame.width * 0.36),
            min(
                metrics.captionMaximumWidth,
                max(imageFrame.width - metrics.edgeInset * 2, 0)
            )
        )

        VideoOverlayLabel(
            text: click.caption,
            style: click.captionStyle,
            fontSize: VideoOverlayPresentation.fontSize(
                style: click.captionStyle,
                metrics: metrics,
                contentScale: camera.scale
            ),
            metrics: metrics
        )
        .frame(width: width)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: VideoCaptionSizeKey.self,
                        value: proxy.size
                    )
            }
        }
        .onPreferenceChange(VideoCaptionSizeKey.self) {
            labelSize = $0
        }
        .scaleEffect(captionScale)
        .position(
            x: captionOrigin.x + fittedLabelSize.width / 2,
            y: captionOrigin.y + fittedLabelSize.height / 2
        )
    }

    private var captionScale: CGFloat {
        VideoOverlayLayout.captionFitScale(labelSize: labelSize, in: imageFrame, metrics: metrics)
    }

    private var fittedLabelSize: CGSize {
        CGSize(width: labelSize.width * captionScale, height: labelSize.height * captionScale)
    }

    private var captionOrigin: CGPoint {
        let point = VideoOverlayPresentation.descriptionPoint(for: click, camera: camera)
        return VideoOverlayLayout.captionOrigin(
            labelSize: fittedLabelSize,
            x: point.x,
            y: point.y,
            in: imageFrame,
            axis: .topDown,
            metrics: metrics
        )
    }
}

private struct VideoCaptionSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 1, height: 1)

    static func reduce(
        value: inout CGSize,
        nextValue: () -> CGSize
    ) {
        value = nextValue()
    }
}

private struct VideoOverlayLabel: View {
    let text: String
    let style: TextOverlayStyle
    let fontSize: CGFloat
    let metrics: VideoOverlayMetrics

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Color(hex: style.foregroundHex))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(
                Color(hex: style.backgroundHex)
                    .opacity(style.backgroundOpacity),
                in: RoundedRectangle(
                    cornerRadius: metrics.cornerRadius
                )
            )
            .shadow(color: .black.opacity(0.36), radius: 4, y: 2)
    }
}
