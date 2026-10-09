import AppKit
import CoreText
import StorybirdCore

enum SubtitlePresentationError: LocalizedError {
    case wordTooWide
    case tooTall
    case cannotRender
    case layer(UUID, String)

    var errorDescription: String? {
        switch self {
        case .wordTooWide:
            "A subtitle word exceeds the safe frame width. Keep the word intact and choose a common smaller size for the subtitle sequence."
        case .tooTall:
            "The complete subtitle exceeds the safe frame height. Divide the full text into timed subtitles using the same font size."
        case .cannotRender:
            "The subtitle image could not be rendered."
        case let .layer(id, reason):
            "Subtitle \(id.uuidString): \(reason)"
        }
    }
}

/// Native preview, MCP PNG and MP4 share output-pixel layout and glyphs. In
/// particular, Core Text's CJK character wrapping must not split Korean eojeol.
enum SubtitleTextRenderer {
    struct Line: Sendable {
        let text: String
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let height: CGFloat
    }

    struct Layout: Sendable {
        let lines: [Line]
        let fontSize: CGFloat
        let size: CGSize
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let fontSize: Double
        let width: CGFloat
        let height: CGFloat
    }

    private final class LayoutCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [Key: Layout] = [:]

        func value(for key: Key) -> Layout? { lock.withLock { values[key] } }
        func insert(_ value: Layout, for key: Key) {
            lock.withLock {
                if values.count >= 128 { values.removeAll(keepingCapacity: true) }
                values[key] = value
            }
        }
    }

    private static let layouts = LayoutCache()
    private static let rasters = OverlayRasterCache()

    static func layout(text: String, style: TextOverlayStyle, frameSize: CGSize) throws -> Layout {
        let key = Key(text: text, fontSize: style.fontSize, width: frameSize.width, height: frameSize.height)
        if let cached = layouts.value(for: key) { return cached }
        let metrics = VideoOverlayMetrics(frameSize: frameSize)
        let fontSize = VideoOverlayPresentation.fontSize(style: style, metrics: metrics)
        let maximumWidth = metrics.subtitleMaximumWidth - metrics.horizontalPadding * 2
        let maximumHeight = frameSize.height - metrics.subtitleInset * 2
        guard maximumWidth > 0, maximumHeight > metrics.verticalPadding * 2,
              fontSize.isFinite, fontSize <= maximumHeight - metrics.verticalPadding * 2 else {
            throw SubtitlePresentationError.tooTall
        }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
        func measure(_ text: String) -> Line {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            var ascent = CTFontGetAscent(font)
            var descent = CTFontGetDescent(font)
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return Line(text: text, width: ceil(width), ascent: ceil(ascent), descent: ceil(descent),
                        height: ceil(max(ascent + descent + leading, fontSize * 1.35)))
        }
        var lines: [Line] = []
        var height = metrics.verticalPadding * 2
        func append(_ text: String) throws {
            let line = measure(text)
            height += line.height
            guard height <= maximumHeight else { throw SubtitlePresentationError.tooTall }
            lines.append(line)
        }
        // Explicit newlines remain paragraph boundaries, including empty lines.
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        for paragraph in paragraphs {
            var current = ""
            var separator = ""
            var word = ""
            func finishWord() throws {
                guard !word.isEmpty else { return }
                guard measure(word).width <= maximumWidth else { throw SubtitlePresentationError.wordTooWide }
                let candidate = (current.isEmpty ? "" : current + separator) + word
                if !current.isEmpty && measure(candidate).width > maximumWidth {
                    try append(current)
                    current = word
                } else {
                    current = candidate
                }
                word = ""
                separator = ""
            }
            for character in paragraph {
                if character.isWhitespace {
                    try finishWord()
                    separator.append(character)
                } else {
                    word.append(character)
                }
            }
            try finishWord()
            try append(current)
        }
        let result = Layout(lines: lines, fontSize: fontSize,
            size: CGSize(width: min(metrics.subtitleMaximumWidth,
                                   (lines.map(\.width).max() ?? 0) + metrics.horizontalPadding * 2),
                         height: height),
            horizontalPadding: metrics.horizontalPadding, verticalPadding: metrics.verticalPadding)
        layouts.insert(result, for: key)
        return result
    }

    static func image(text: String, style: TextOverlayStyle, frameSize: CGSize) throws -> CGImage {
        let layout = try layout(text: text, style: style, frameSize: frameSize)
        let key = OverlayRasterCache.Key.subtitle(text, fontSize: style.fontSize,
            width: frameSize.width, height: frameSize.height, foreground: style.foregroundHex,
            background: style.backgroundHex, opacity: style.backgroundOpacity)
        guard let image = rasters.image(for: key, create: {
            guard let context = CGContext(data: nil, width: max(1, Int(ceil(layout.size.width))),
                height: max(1, Int(ceil(layout.size.height))), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(color(style.backgroundHex, opacity: style.backgroundOpacity))
            context.fill(CGRect(origin: .zero, size: layout.size))
            let font = NSFont.systemFont(ofSize: layout.fontSize, weight: .semibold)
            var top = layout.size.height - layout.verticalPadding
            for line in layout.lines {
                let attributed = NSAttributedString(string: line.text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: color(style.foregroundHex, opacity: 1),
                ])
                context.textPosition = CGPoint(x: (layout.size.width - line.width) / 2,
                    y: top - (line.height - line.ascent - line.descent) / 2 - line.ascent)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                top -= line.height
            }
            return context.makeImage()
        }) else { throw SubtitlePresentationError.cannotRender }
        return image
    }

    static func validate(_ project: DemoProject, at time: Double? = nil) throws {
        guard let recording = project.recording else { return }
        let size = CGSize(width: recording.width, height: recording.height)
        let subtitles = project.subtitles + project.clicks.map {
            TimedSubtitle(id: $0.id, startTime: $0.cueSubtitle.startTime, endTime: $0.cueSubtitle.endTime,
                          text: $0.cueSubtitle.text, position: $0.cueSubtitle.position, style: $0.cueSubtitle.style)
        }
        for subtitle in subtitles where !subtitle.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let time, !(subtitle.startTime <= time && time <= subtitle.endTime) { continue }
            do {
                _ = try layout(text: subtitle.text, style: subtitle.style, frameSize: size)
            } catch {
                throw SubtitlePresentationError.layer(subtitle.id, error.localizedDescription)
            }
        }
    }

    private static func color(_ hex: String, opacity: Double) -> CGColor {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0
        return CGColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: opacity)
    }
}
