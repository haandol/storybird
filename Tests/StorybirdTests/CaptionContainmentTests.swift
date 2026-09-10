import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class CaptionContainmentTests: XCTestCase {
    func test_largeAutomaticCaption_remainsInsideSmallPreviewAtEveryCorner() async throws {
        for scale in [1.0, 3.0] {
            for (x, y) in [(0.02, 0.02), (0.98, 0.02), (0.02, 0.98), (0.98, 0.98)] {
                let frame = CGRect(x: 80, y: 80, width: 320, height: 76)
                var project = DemoProject(name: "Caption fit", recording:
                    VideoRecordingAsset(filename: "synthetic.mp4", duration: 10, width: 1920, height: 1080))
                project = try VideoTimelineEditor.addClickCue(to: project, at: 1, x: x, y: y)
                if scale > 1 {
                    project.effects = [.panZoom(PanZoomEffect(
                        startTime: 0, endTime: 2, startX: 0.6, startY: 0.3, startScale: scale,
                        endX: 0.6, endY: 0.3, endScale: scale
                    ))]
                }
                project.clicks[0].indicator.opacity = 0
                project.clicks[0].description.text = "A large automatic caption with several lines"
                project.clicks[0].description.style.fontSize = 96
                project.clicks[0].description.style.backgroundHex = "#FF0000"
                project.clicks[0].description.style.backgroundOpacity = 1
                let view = NSHostingView(rootView: VideoOverlayCanvas(project: project, time: 1, imageFrame: frame,
                    camera: VideoOverlayPresentation.camera(in: project, at: 1))
                    .frame(width: 480, height: 320).background(.white))
                let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 480, height: 320),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(180))
                view.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let debugURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/caption-before.png")
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: debugURL)
                let bounds = try redBounds(image, viewSize: view.bounds.size)
                XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(bounds), "\(bounds) outside \(frame)")
                if x > 0.5 && y > 0.5 {
                    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/authoring-evidence")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("caption-small-preview.png"))
                }
            }
        }
    }

    /// Measures the actual raster's red caption background, excluding white text and shadows.
    private func redBounds(_ image: NSBitmapImageRep, viewSize: CGSize) throws -> CGRect {
        var minimum = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        var maximum = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 else { continue }
                minimum.x = min(minimum.x, CGFloat(x))
                minimum.y = min(minimum.y, CGFloat(y))
                maximum.x = max(maximum.x, CGFloat(x))
                maximum.y = max(maximum.y, CGFloat(y))
            }
        }
        XCTAssertTrue(minimum.x.isFinite, "The caption must actually render.")
        guard minimum.x.isFinite else { throw CocoaError(.coderInvalidValue) }
        let xScale = viewSize.width / CGFloat(image.pixelsWide)
        let yScale = viewSize.height / CGFloat(image.pixelsHigh)
        return CGRect(x: minimum.x * xScale, y: minimum.y * yScale,
            width: (maximum.x - minimum.x) * xScale, height: (maximum.y - minimum.y) * yScale)
    }
}
