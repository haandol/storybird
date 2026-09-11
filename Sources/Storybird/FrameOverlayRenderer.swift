import CoreImage
import CoreMedia
import CoreText
import Foundation
import StorybirdCore

enum FrameOverlayRenderer {
    private static let rasters = OverlayRasterCache()

    /// Applies content camera motion before adding content-linked and screen-fixed overlays.
    static func compositeFrameOverlays(
        project: DemoProject,
        over source: CIImage,
        at presentationTime: CMTime,
        frame: CGRect
    ) -> CIImage {
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let time = CMTimeGetSeconds(presentationTime)
        guard time.isFinite else { return source }
        let camera = VideoOverlayPresentation.camera(
            in: project,
            at: time
        )
        var result = applyCamera(camera, to: source, frame: frame)

        if let spotlight = project.effects.compactMap({
            if case let .spotlight(value) = $0,
               value.startTime <= time,
               time <= value.endTime {
                return value
            }
            return nil
        }).first,
            let mask = makeSpotlightImage(
                spotlight,
                frame: frame
            ) {
            result = CIImage(cgImage: mask).composited(over: result)
        }

        for click in project.clicks where
            click.indicator.startTime <= time
                && time <= click.indicator.endTime {
            let presentation = VideoOverlayPresentation.clickRing(
                for: click,
                at: time,
                camera: camera
            )
            let center = VideoOverlayLayout.clickPoint(
                x: presentation.point.x,
                y: presentation.point.y,
                in: frame,
                axis: .bottomUp
            )
            let diameter = metrics.clickRingDiameter
                * click.indicator.size
                * CGFloat(camera.scale)
                * CGFloat(presentation.diameterScale)
            if let ring = makeRingImage(
                size: CGSize(width: diameter, height: diameter),
                color: color(
                    hex: click.indicator.colorHex,
                    opacity: click.indicator.opacity
                        * presentation.opacityScale
                )
            ) {
                result = CIImage(cgImage: ring)
                    .transformed(
                        by: CGAffineTransform(
                            translationX: center.x - diameter / 2,
                            y: center.y - diameter / 2
                        )
                    )
                    .composited(over: result)
            }
        }

        for click in project.clicks where
            !click.caption.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && click.description.startTime <= time
                && time <= click.description.endTime {
            let transformed = VideoOverlayPresentation.descriptionPoint(
                for: click,
                camera: camera
            )
            let fontSize = VideoOverlayPresentation.fontSize(
                style: click.description.style,
                metrics: metrics,
                contentScale: camera.scale
            )
            let geometry = labelGeometry(
                text: click.caption,
                fontSize: fontSize,
                maximumWidth: min(
                    metrics.captionMaximumWidth,
                    frame.width - metrics.edgeInset * 2
                ),
                lineLimit: 3,
                metrics: metrics
            )
            let fit = VideoOverlayLayout.captionFitScale(
                labelSize: geometry.containerSize,
                in: frame,
                metrics: metrics
            )
            let origin = VideoOverlayLayout.captionOrigin(
                labelSize: CGSize(
                    width: geometry.containerSize.width * fit,
                    height: geometry.containerSize.height * fit
                ),
                x: transformed.x,
                y: transformed.y,
                in: frame,
                axis: .bottomUp,
                metrics: metrics
            )
            // Fit the entire measured caption, including padding, as the native
            // canvas does. Scaling one composed label preserves its line breaks.
            let caption = compositeLabel(
                click.caption,
                fontSize: fontSize,
                origin: .zero,
                geometry: geometry,
                style: click.description.style,
                over: CIImage.empty()
            )
            result = caption
                .cropped(to: CGRect(origin: .zero, size: geometry.containerSize))
                .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                .composited(over: result)
        }

        for click in project.clicks where
            click.cueSubtitle.startTime <= time
                && time <= click.cueSubtitle.endTime
                && !click.cueSubtitle.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
            result = compositeSubtitleText(
                click.cueSubtitle.text,
                style: click.cueSubtitle.style,
                position: click.cueSubtitle.position,
                over: result,
                frame: frame,
                metrics: metrics
            )
        }

        for subtitle in project.subtitles where
            subtitle.startTime <= time
                && time <= subtitle.endTime
                && !subtitle.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
            result = compositeSubtitleText(
                subtitle.text,
                style: subtitle.style,
                position: subtitle.position,
                over: result,
                frame: frame,
                metrics: metrics
            )
        }

        for effect in project.effects where
            effect.startTime <= time && time <= effect.endTime {
            switch effect {
            case let .title(value):
                result = compositeCard(
                    title: value.title,
                    secondary: value.subtitle,
                    style: value.style,
                    over: result,
                    frame: frame
                )
            case let .cta(value):
                result = compositeCard(
                    title: value.title,
                    secondary: value.buttonLabel,
                    style: value.style,
                    over: result,
                    frame: frame
                )
            case .spotlight, .panZoom:
                break
            }
        }

        if project.theme.showsBranding {
            let size = CGSize(
                width: min(180 * metrics.scale, frame.width / 2),
                height: 18 * metrics.scale
            )
            result = compositeTextRaster(
                "Made with Storybird",
                fontSize: 12 * metrics.scale,
                in: CGRect(
                    x: frame.width - size.width - metrics.subtitleInset,
                    y: 10 * metrics.scale,
                    width: size.width,
                    height: size.height
                ),
                over: result
            )
        }
        return result
    }

    private static func applyCamera(
        _ camera: VideoCameraPresentation,
        to source: CIImage,
        frame: CGRect
    ) -> CIImage {
        guard abs(camera.scale - 1) > 0.0001
                || abs(camera.x - 0.5) > 0.0001
                || abs(camera.y - 0.5) > 0.0001
        else {
            return source
        }
        let center = CGPoint(
            x: CGFloat(camera.x) * frame.width,
            y: (1 - CGFloat(camera.y)) * frame.height
        )
        let transform = CGAffineTransform(
            translationX: frame.midX,
            y: frame.midY
        )
        .scaledBy(
            x: CGFloat(camera.scale),
            y: CGFloat(camera.scale)
        )
        .translatedBy(x: -center.x, y: -center.y)
        return source.transformed(by: transform).cropped(to: frame)
    }

    private static func compositeSubtitleText(
        _ text: String,
        style: TextOverlayStyle,
        position: SubtitlePosition,
        over source: CIImage,
        frame: CGRect,
        metrics: VideoOverlayMetrics
    ) -> CIImage {
        let fontSize = VideoOverlayPresentation.fontSize(
            style: style,
            metrics: metrics
        )
        let geometry = labelGeometry(
            text: text,
            fontSize: fontSize,
            maximumWidth: min(
                metrics.subtitleMaximumWidth,
                frame.width - metrics.subtitleInset * 2
            ),
            lineLimit: 3,
            metrics: metrics
        )
        let origin = CGPoint(
            x: (frame.width - geometry.containerSize.width) / 2,
            y: position == .top
                ? frame.height
                    - geometry.containerSize.height
                    - metrics.subtitleInset
                : metrics.subtitleInset
        )
        return compositeLabel(
            text,
            fontSize: fontSize,
            origin: origin,
            geometry: geometry,
            style: style,
            over: source
        )
    }

    private static func compositeLabel(
        _ text: String,
        fontSize: CGFloat,
        origin: CGPoint,
        geometry: (containerSize: CGSize, textRect: CGRect),
        style: TextOverlayStyle,
        over source: CIImage
    ) -> CIImage {
        let background = CIImage(
            color: CIColor(
                cgColor: color(
                    hex: style.backgroundHex,
                    opacity: style.backgroundOpacity
                )
            )
        ).cropped(
            to: CGRect(origin: origin, size: geometry.containerSize)
        )
        let withBackground = background.composited(over: source)
        return compositeTextRaster(
            text,
            fontSize: fontSize,
            in: geometry.textRect.offsetBy(
                dx: origin.x,
                dy: origin.y
            ),
            foregroundHex: style.foregroundHex,
            over: withBackground
        )
    }

    private static func compositeCard(
        title: String,
        secondary: String,
        style: TextOverlayStyle,
        over source: CIImage,
        frame: CGRect
    ) -> CIImage {
        let metrics = VideoOverlayMetrics(frameSize: frame.size)
        let background = CIImage(
            color: CIColor(
                cgColor: color(
                    hex: style.backgroundHex,
                    opacity: style.backgroundOpacity
                )
            )
        ).cropped(to: frame)
        var result = background.composited(over: source)
        result = compositeTextRaster(
            title,
            fontSize: VideoOverlayPresentation.cardTitleFontSize(
                style: style,
                metrics: metrics
            ),
            in: CGRect(
                x: frame.width * 0.15,
                y: frame.height * 0.48,
                width: frame.width * 0.7,
                height: frame.height * 0.18
            ),
            foregroundHex: style.foregroundHex,
            over: result
        )
        if !secondary.isEmpty {
            let labelRect = CGRect(
                x: frame.width * 0.25,
                y: frame.height * 0.31,
                width: frame.width * 0.5,
                height: frame.height * 0.14
            )
            let labelBackground = CIImage(
                color: CIColor(
                    cgColor: color(
                        hex: style.foregroundHex,
                        opacity: 0.15
                    )
                )
            ).cropped(to: labelRect)
            result = labelBackground.composited(over: result)
            result = compositeTextRaster(
                secondary,
                fontSize:
                    VideoOverlayPresentation.cardSecondaryFontSize(
                        style: style,
                        metrics: metrics
                    ),
                in: CGRect(
                    x: frame.width * 0.25,
                    y: frame.height * 0.33,
                    width: frame.width * 0.5,
                    height: frame.height * 0.1
                ),
                foregroundHex: style.foregroundHex,
                over: result
            )
        }
        return result
    }

    private static func makeRingImage(
        size: CGSize,
        color: CGColor
    ) -> CGImage? {
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setStrokeColor(color)
        context.setFillColor(color.copy(alpha: 0.18) ?? color)
        let lineWidth = max(size.width * 0.08, 2)
        context.setLineWidth(lineWidth)
        let rect = CGRect(
            x: lineWidth / 2,
            y: lineWidth / 2,
            width: size.width - lineWidth,
            height: size.height - lineWidth
        )
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
        return context.makeImage()
    }

    private static func makeSpotlightImage(
        _ effect: SpotlightEffect,
        frame: CGRect
    ) -> CGImage? {
        rasters.image(for: .spotlight(
            x: effect.x, y: effect.y, width: effect.width, height: effect.height,
            opacity: effect.dimOpacity, frameX: frame.minX, frameY: frame.minY,
            frameWidth: frame.width, frameHeight: frame.height
        )) {
            drawSpotlightImage(effect, frame: frame)
        }
    }

    private static func drawSpotlightImage(_ effect: SpotlightEffect, frame: CGRect) -> CGImage? {
        let width = max(Int(ceil(frame.width)), 1)
        let height = max(Int(ceil(frame.height)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 0, alpha: effect.dimOpacity))
        context.fill(frame)
        context.setBlendMode(.clear)
        context.fill(
            CGRect(
                x: effect.x * frame.width,
                y: (1 - effect.y - effect.height) * frame.height,
                width: effect.width * frame.width,
                height: effect.height * frame.height
            )
        )
        return context.makeImage()
    }

    private static func labelGeometry(
        text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineLimit: Int,
        metrics: VideoOverlayMetrics
    ) -> (containerSize: CGSize, textRect: CGRect) {
        let contentWidth = max(
            maximumWidth - metrics.horizontalPadding * 2,
            1
        )
        let textSize = measureText(
            text,
            fontSize: fontSize,
            maximumWidth: contentWidth,
            lineLimit: lineLimit
        )
        let containerSize = CGSize(
            width: min(
                textSize.width + metrics.horizontalPadding * 2,
                maximumWidth
            ),
            height: textSize.height + metrics.verticalPadding * 2
        )
        return (
            containerSize,
            CGRect(
                x: metrics.horizontalPadding,
                y: metrics.verticalPadding,
                width: max(
                    containerSize.width - metrics.horizontalPadding * 2,
                    1
                ),
                height: max(
                    containerSize.height - metrics.verticalPadding * 2,
                    1
                )
            )
        )
    }

    private static func compositeTextRaster(
        _ text: String,
        fontSize: CGFloat,
        in rect: CGRect,
        foregroundHex: String = "#FFFFFF",
        over source: CIImage
    ) -> CIImage {
        guard let image = makeTextImage(
            text,
            fontSize: fontSize,
            size: rect.size,
            foregroundHex: foregroundHex
        ) else {
            return source
        }
        let overlay = CIImage(cgImage: image)
            .transformed(
                by: CGAffineTransform(
                    scaleX: 0.5,
                    y: 0.5
                )
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: rect.minX,
                    y: rect.minY
                )
            )
        return overlay.composited(over: source)
    }

    /// Rasterizes Core Text before video composition so glyphs use the same reliable layer path as backgrounds.
    static func makeTextImage(
        _ text: String,
        fontSize: CGFloat,
        size: CGSize,
        foregroundHex: String = "#FFFFFF"
    ) -> CGImage? {
        rasters.image(for: .text(
            text, fontSize: fontSize, width: size.width, height: size.height, color: foregroundHex
        )) {
            drawTextImage(text, fontSize: fontSize, size: size, foregroundHex: foregroundHex)
        }
    }

    private static func drawTextImage(
        _ text: String, fontSize: CGFloat, size: CGSize, foregroundHex: String
    ) -> CGImage? {
        let scale: CGFloat = 2
        let width = max(Int(ceil(size.width * scale)), 1)
        let height = max(Int(ceil(size.height * scale)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraphStyle: CTParagraphStyle = withUnsafePointer(
            to: &alignment
        ) { alignmentPointer in
            withUnsafePointer(to: &lineBreak) { lineBreakPointer in
                var settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: lineBreakPointer
                    ),
                ]
                return CTParagraphStyleCreate(
                    &settings,
                    settings.count
                )
            }
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName
                    as NSAttributedString.Key: color(
                        hex: foregroundHex,
                        opacity: 1
                    ),
                kCTParagraphStyleAttributeName
                    as NSAttributedString.Key: paragraphStyle,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed
        )
        let path = CGPath(
            rect: CGRect(origin: .zero, size: size),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// Measures Core Text within the same width and line-height ceiling used by the output layer.
    private static func measureText(
        _ text: String,
        fontSize: CGFloat,
        maximumWidth: CGFloat,
        lineLimit: Int
    ) -> CGSize {
        rasters.textSize(text, fontSize: fontSize, width: maximumWidth, lineLimit: lineLimit) {
            measureUncachedText(text, fontSize: fontSize, maximumWidth: maximumWidth, lineLimit: lineLimit)
        }
    }

    private static func measureUncachedText(
        _ text: String, fontSize: CGFloat, maximumWidth: CGFloat, lineLimit: Int
    ) -> CGSize {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(
            width: min(ceil(suggested.width), maximumWidth),
            height: min(
                ceil(suggested.height),
                ceil(fontSize * 1.35 * CGFloat(lineLimit))
            )
        )
    }

    /// Parses the persisted six-digit color without allowing invalid project text into Core Animation.
    private static func color(
        hex: String,
        opacity: Double
    ) -> CGColor {
        let cleaned = hex.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16)
        else {
            return CGColor(
                red: 0.067,
                green: 0.075,
                blue: 0.102,
                alpha: min(max(opacity, 0), 1)
            )
        }
        return CGColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: min(max(opacity, 0), 1)
        )
    }
}
