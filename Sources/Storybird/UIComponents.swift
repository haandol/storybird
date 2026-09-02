import AppKit
import StorybirdCore
import SwiftUI

struct StorybirdMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#7273F4"), Color(hex: "#4546C7")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Path { path in
                path.move(to: CGPoint(x: size * 0.28, y: size * 0.77))
                path.addCurve(
                    to: CGPoint(x: size * 0.72, y: size * 0.23),
                    control1: CGPoint(x: size * 0.43, y: size * 0.61),
                    control2: CGPoint(x: size * 0.57, y: size * 0.39)
                )
            }
            .stroke(.white, style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round))

            Circle()
                .fill(.white)
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.22, y: -size * 0.27)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: "#4546C7").opacity(0.24), radius: size * 0.16, y: size * 0.08)
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
