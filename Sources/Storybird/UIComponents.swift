import AppKit
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

extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        guard value.count == 6, let number = Int(value, radix: 16) else {
            self = Color.accentColor
            return
        }
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
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
