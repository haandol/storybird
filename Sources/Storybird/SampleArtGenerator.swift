import AppKit

enum SampleArtGenerator {
    struct Screen {
        var title: String
        var caption: String
        var image: NSImage
    }

    static func makeScreens() -> [Screen] {
        [
            Screen(
                title: "Your demo library",
                caption: "Keep every interactive product story in one private workspace.",
                image: libraryScreen()
            ),
            Screen(
                title: "Build the guided path",
                caption: "Connect screenshots with clear, contextual hotspots.",
                image: editorScreen()
            ),
            Screen(
                title: "Share a standalone demo",
                caption: "Export a polished experience that opens in any modern browser.",
                image: publishScreen()
            ),
        ]
    }

    private static let size = NSSize(width: 1440, height: 900)
    private static let ink = NSColor(
        calibratedRed: 0.10,
        green: 0.11,
        blue: 0.15,
        alpha: 1
    )
    private static let panel = NSColor(
        calibratedRed: 0.96,
        green: 0.96,
        blue: 0.98,
        alpha: 1
    )
    private static let purple = NSColor(
        calibratedRed: 0.36,
        green: 0.36,
        blue: 0.89,
        alpha: 1
    )

    private static func libraryScreen() -> NSImage {
        render { canvas in
            drawChrome(canvas, title: "Storybird")
            fill(
                NSRect(x: 0, y: 0, width: 250, height: 838),
                color: NSColor(calibratedWhite: 0.10, alpha: 1)
            )
            text("WORKSPACE", at: NSPoint(x: 30, y: 770), size: 13, color: .gray)
            sidebarRow("Demo library", y: 716, selected: true)
            sidebarRow("Recent captures", y: 662)
            sidebarRow("Exports", y: 608)

            text("Demo library", at: NSPoint(x: 300, y: 750), size: 36, weight: .bold)
            text(
                "Build clear, self-guided product stories.",
                at: NSPoint(x: 300, y: 708),
                size: 18,
                color: .secondaryLabelColor
            )
            button("New demo", rect: NSRect(x: 1110, y: 716, width: 170, height: 48))

            card(
                rect: NSRect(x: 300, y: 420, width: 290, height: 220),
                title: "Customer onboarding",
                subtitle: "6 screens · Edited today",
                accent: purple
            )
            card(
                rect: NSRect(x: 620, y: 420, width: 290, height: 220),
                title: "Analytics overview",
                subtitle: "4 screens · Yesterday",
                accent: NSColor.systemTeal
            )
            card(
                rect: NSRect(x: 940, y: 420, width: 290, height: 220),
                title: "Feature launch",
                subtitle: "8 screens · Aug 29",
                accent: NSColor.systemOrange
            )

            text("Recent activity", at: NSPoint(x: 300, y: 350), size: 22, weight: .semibold)
            metric(rect: NSRect(x: 300, y: 170, width: 280, height: 130), value: "126", label: "Preview sessions")
            metric(rect: NSRect(x: 610, y: 170, width: 280, height: 130), value: "73%", label: "Completion rate")
            metric(rect: NSRect(x: 920, y: 170, width: 280, height: 130), value: "482", label: "Hotspot clicks")
        }
    }

    private static func editorScreen() -> NSImage {
        render { canvas in
            drawChrome(canvas, title: "Customer onboarding")
            fill(NSRect(x: 0, y: 0, width: 226, height: 838), color: NSColor(calibratedWhite: 0.12, alpha: 1))
            fill(NSRect(x: 1130, y: 0, width: 310, height: 838), color: panel)

            text("SCREENS", at: NSPoint(x: 24, y: 785), size: 12, color: .gray)
            thumbnail(y: 620, number: 1, selected: false)
            thumbnail(y: 452, number: 2, selected: true)
            thumbnail(y: 284, number: 3, selected: false)

            fill(
                NSRect(x: 270, y: 150, width: 815, height: 550),
                color: NSColor(calibratedWhite: 0.075, alpha: 1),
                radius: 18
            )
            fill(
                NSRect(x: 325, y: 206, width: 705, height: 438),
                color: .white,
                radius: 12
            )
            fill(NSRect(x: 325, y: 586, width: 705, height: 58), color: ink, radius: 12)
            text("Acme Cloud", at: NSPoint(x: 350, y: 605), size: 18, color: .white, weight: .semibold)
            text("Welcome back, Morgan", at: NSPoint(x: 370, y: 505), size: 30, weight: .bold)
            fill(NSRect(x: 370, y: 340, width: 280, height: 110), color: NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.99, alpha: 1), radius: 12)
            fill(NSRect(x: 680, y: 340, width: 280, height: 110), color: NSColor(calibratedRed: 0.91, green: 0.97, blue: 0.95, alpha: 1), radius: 12)
            fill(NSRect(x: 370, y: 255, width: 590, height: 52), color: NSColor(calibratedWhite: 0.94, alpha: 1), radius: 10)

            fillCircle(center: NSPoint(x: 810, y: 430), radius: 23, color: purple)
            text("1", at: NSPoint(x: 804, y: 420), size: 16, color: .white, weight: .bold)
            strokeCircle(center: NSPoint(x: 810, y: 430), radius: 34, color: purple.withAlphaComponent(0.25), width: 8)

            text("Hotspot", at: NSPoint(x: 1160, y: 770), size: 22, weight: .bold)
            label("TITLE", y: 712)
            field("Guide the viewer", y: 658)
            label("DESCRIPTION", y: 604)
            fill(NSRect(x: 1160, y: 490, width: 240, height: 94), color: .white, radius: 8)
            text("Explain what happens here and", at: NSPoint(x: 1174, y: 548), size: 14, color: .secondaryLabelColor)
            text("why it matters.", at: NSPoint(x: 1174, y: 524), size: 14, color: .secondaryLabelColor)
            label("LEADS TO", y: 432)
            field("3. Share the demo", y: 378)
        }
    }

    private static func publishScreen() -> NSImage {
        render { canvas in
            fill(canvas, color: ink)
            text("INTERACTIVE DEMO", at: NSPoint(x: 110, y: 785), size: 13, color: NSColor(calibratedWhite: 0.62, alpha: 1), weight: .bold)
            text("A product story anyone can follow", at: NSPoint(x: 110, y: 718), size: 38, color: .white, weight: .bold)
            text("3 / 3", at: NSPoint(x: 1250, y: 735), size: 16, color: NSColor(calibratedWhite: 0.68, alpha: 1))

            fill(
                NSRect(x: 110, y: 130, width: 1220, height: 520),
                color: NSColor(calibratedWhite: 0.045, alpha: 1),
                radius: 22
            )
            fill(
                NSRect(x: 180, y: 190, width: 1080, height: 400),
                color: NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
                radius: 14
            )
            fill(NSRect(x: 180, y: 530, width: 1080, height: 60), color: purple, radius: 14)
            text("Acme Cloud", at: NSPoint(x: 215, y: 550), size: 20, color: .white, weight: .semibold)
            text("Your workspace is ready", at: NSPoint(x: 245, y: 430), size: 36, weight: .bold)
            text("Invite your team, connect data, and launch your first workflow.", at: NSPoint(x: 245, y: 382), size: 19, color: .secondaryLabelColor)
            button("Invite teammates", rect: NSRect(x: 245, y: 290, width: 190, height: 50))
            fillCircle(center: NSPoint(x: 1130, y: 552), radius: 24, color: .white)
            text("1", at: NSPoint(x: 1124, y: 542), size: 16, color: purple, weight: .bold)
            strokeCircle(center: NSPoint(x: 1130, y: 552), radius: 36, color: .white.withAlphaComponent(0.26), width: 8)

            text("Made with Storybird", at: NSPoint(x: 646, y: 76), size: 13, color: NSColor(calibratedWhite: 0.46, alpha: 1))
        }
    }

    private static func render(_ drawing: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        drawing(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    private static func drawChrome(_ rect: NSRect, title: String) {
        fill(rect, color: panel)
        fill(NSRect(x: 0, y: 838, width: 1440, height: 62), color: ink)
        fillCircle(center: NSPoint(x: 25, y: 868), radius: 6, color: .systemRed)
        fillCircle(center: NSPoint(x: 45, y: 868), radius: 6, color: .systemYellow)
        fillCircle(center: NSPoint(x: 65, y: 868), radius: 6, color: .systemGreen)
        text(title, at: NSPoint(x: 700, y: 856), size: 15, color: .white, weight: .medium)
    }

    private static func sidebarRow(_ value: String, y: CGFloat, selected: Bool = false) {
        if selected {
            fill(NSRect(x: 18, y: y - 13, width: 214, height: 48), color: purple.withAlphaComponent(0.24), radius: 10)
        }
        text(value, at: NSPoint(x: 36, y: y), size: 16, color: selected ? .white : NSColor(calibratedWhite: 0.68, alpha: 1), weight: selected ? .semibold : .regular)
    }

    private static func card(rect: NSRect, title: String, subtitle: String, accent: NSColor) {
        fill(rect, color: .white, radius: 16)
        fill(NSRect(x: rect.minX, y: rect.maxY - 92, width: rect.width, height: 92), color: accent, radius: 16)
        fill(NSRect(x: rect.minX, y: rect.maxY - 92, width: rect.width, height: 18), color: accent)
        text(title, at: NSPoint(x: rect.minX + 22, y: rect.minY + 72), size: 18, weight: .semibold)
        text(subtitle, at: NSPoint(x: rect.minX + 22, y: rect.minY + 38), size: 14, color: .secondaryLabelColor)
    }

    private static func metric(rect: NSRect, value: String, label: String) {
        fill(rect, color: .white, radius: 14)
        text(value, at: NSPoint(x: rect.minX + 22, y: rect.minY + 67), size: 34, weight: .bold)
        text(label, at: NSPoint(x: rect.minX + 22, y: rect.minY + 32), size: 14, color: .secondaryLabelColor)
    }

    private static func thumbnail(y: CGFloat, number: Int, selected: Bool) {
        let rect = NSRect(x: 20, y: y, width: 186, height: 130)
        fill(rect, color: selected ? purple : NSColor(calibratedWhite: 0.22, alpha: 1), radius: 11)
        fill(rect.insetBy(dx: 5, dy: 5), color: NSColor(calibratedWhite: 0.92, alpha: 1), radius: 8)
        fill(NSRect(x: 38, y: y + 78, width: 150, height: 24), color: ink, radius: 5)
        fill(NSRect(x: 44, y: y + 28, width: 62, height: 36), color: purple.withAlphaComponent(0.18), radius: 5)
        fill(NSRect(x: 116, y: y + 28, width: 62, height: 36), color: NSColor.systemTeal.withAlphaComponent(0.18), radius: 5)
        fillCircle(center: NSPoint(x: 30, y: y + 116), radius: 14, color: selected ? purple : ink)
        text("\(number)", at: NSPoint(x: 26, y: y + 107), size: 13, color: .white, weight: .bold)
    }

    private static func label(_ value: String, y: CGFloat) {
        text(value, at: NSPoint(x: 1160, y: y), size: 11, color: .secondaryLabelColor, weight: .bold)
    }

    private static func field(_ value: String, y: CGFloat) {
        fill(NSRect(x: 1160, y: y, width: 240, height: 40), color: .white, radius: 8)
        text(value, at: NSPoint(x: 1174, y: y + 12), size: 14, color: ink)
    }

    private static func button(_ value: String, rect: NSRect) {
        fill(rect, color: purple, radius: 11)
        let attributes = attributes(size: 16, color: .white, weight: .semibold)
        let width = (value as NSString).size(withAttributes: attributes).width
        (value as NSString).draw(
            at: NSPoint(
                x: rect.midX - width / 2,
                y: rect.midY - 10
            ),
            withAttributes: attributes
        )
    }

    private static func fill(_ rect: NSRect, color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        if radius > 0 {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        } else {
            rect.fill()
        }
    }

    private static func fillCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
    }

    private static func strokeCircle(
        center: NSPoint,
        radius: CGFloat,
        color: NSColor,
        width: CGFloat
    ) {
        color.setStroke()
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        path.lineWidth = width
        path.stroke()
    }

    private static func text(
        _ value: String,
        at point: NSPoint,
        size: CGFloat,
        color: NSColor = ink,
        weight: NSFont.Weight = .regular
    ) {
        (value as NSString).draw(
            at: point,
            withAttributes: attributes(size: size, color: color, weight: weight)
        )
    }

    private static func attributes(
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    }
}
