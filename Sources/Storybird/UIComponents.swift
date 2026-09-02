import AppKit
import StorybirdCore
import SwiftUI

struct StorybirdMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct AssetImageView: View {
    let url: URL
    var contentMode: ContentMode = .fit

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            ZStack {
                Color.secondary.opacity(0.08)
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ScreenSubtitleOverlay: View {
    let text: String
    let position: SubtitlePosition
    let style: TextOverlayStyle
    let imageFrame: CGRect

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if !trimmedText.isEmpty,
           imageFrame.width > 32,
           imageFrame.height > 32 {
            VStack {
                if position == .bottom {
                    Spacer(minLength: 0)
                }

                TextOverlayLabel(
                    text: trimmedText,
                    style: style,
                    font: .callout.weight(.semibold),
                    lineLimit: 3
                )
                .frame(maxWidth: min(680, imageFrame.width - 32))

                if position == .top {
                    Spacer(minLength: 0)
                }
            }
            .frame(
                width: imageFrame.width - 32,
                height: imageFrame.height - 32
            )
            .position(x: imageFrame.midX, y: imageFrame.midY)
            .allowsHitTesting(false)
        }
    }
}

struct HotspotCaptionOverlay: View {
    let hotspot: Hotspot
    let imageFrame: CGRect

    private var trimmedText: String {
        hotspot.caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if !trimmedText.isEmpty,
           imageFrame.width > 32,
           imageFrame.height > 32 {
            let point = CGPoint(
                x: imageFrame.minX + CGFloat(hotspot.x) * imageFrame.width,
                y: imageFrame.minY + CGFloat(hotspot.y) * imageFrame.height
            )
            let targetWidth = min(190, max(96, imageFrame.width * 0.36))
            let width = min(targetWidth, imageFrame.width - 16)
            let gap = min(30, imageFrame.width * 0.08)
            let desiredX = hotspot.x <= 0.5
                ? point.x + gap + width / 2
                : point.x - gap - width / 2
            let centerX = min(
                max(desiredX, imageFrame.minX + width / 2 + 8),
                imageFrame.maxX - width / 2 - 8
            )
            let verticalMargin = min(38, imageFrame.height / 2)
            let centerY = min(
                max(point.y, imageFrame.minY + verticalMargin),
                imageFrame.maxY - verticalMargin
            )

            TextOverlayLabel(
                text: trimmedText,
                style: hotspot.captionStyle,
                font: .caption.weight(.semibold),
                lineLimit: 3
            )
            .frame(width: width)
            .position(x: centerX, y: centerY)
            .allowsHitTesting(false)
        }
    }
}

private struct TextOverlayLabel: View {
    let text: String
    let style: TextOverlayStyle
    let font: Font
    let lineLimit: Int

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Color(hex: style.backgroundHex)
                    .opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .shadow(color: .black.opacity(0.36), radius: 4, y: 2)
    }
}

struct HotspotMarker: View {
    let number: Int
    let kind: HotspotKind
    let color: Color
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.20))
                .frame(width: isSelected ? 48 : 42, height: isSelected ? 48 : 42)
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .shadow(color: color.opacity(0.35), radius: 7, y: 3)
            Text(kind == .information ? "i" : "\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = Int(value, radix: 16) else {
            self = Color.accentColor
            return
        }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    var hexRGB: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return "#5B5CE2"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

extension AnalyticsEventType {
    var displayName: String {
        switch self {
        case .sessionStarted:
            return "Preview started"
        case .stepViewed:
            return "Screen viewed"
        case .hotspotClicked:
            return "Hotspot clicked"
        case .completed:
            return "Demo completed"
        }
    }

    var systemImage: String {
        switch self {
        case .sessionStarted:
            return "play.circle"
        case .stepViewed:
            return "rectangle.on.rectangle"
        case .hotspotClicked:
            return "cursorarrow.click"
        case .completed:
            return "checkmark.circle"
        }
    }
}
