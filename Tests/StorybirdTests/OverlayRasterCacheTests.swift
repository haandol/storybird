import CoreImage
import CoreMedia
import StorybirdCore
import XCTest
@testable import Storybird

final class OverlayRasterCacheTests: XCTestCase {
    func test_textLayout_changedWrappingInputsRecomputeAndCacheIsBounded() {
        let cache = OverlayRasterCache(countLimit: 1)
        var count = 0
        func size(_ text: String = "Wrap", font: CGFloat = 18, width: CGFloat = 100, lines: Int = 3) -> CGSize {
            cache.textSize(text, fontSize: font, width: width, lineLimit: lines) {
                count += 1
                return CGSize(width: width, height: CGFloat(count))
            }
        }
        XCTAssertEqual(size(), size())
        XCTAssertEqual(count, 1)
        _ = size("Other")
        _ = size("Other", font: 24)
        _ = size("Other", font: 24, width: 60)
        _ = size("Other", font: 24, width: 60, lines: 1)
        XCTAssertEqual(count, 5)
        _ = size()
        XCTAssertEqual(count, 6)
    }

    func test_textRaster_reusesPixelsAndRefreshesTextColorFontAndSize() throws {
        let size = CGSize(width: 200, height: 50)
        let first = try XCTUnwrap(FrameOverlayRenderer.makeTextImage("Hello", fontSize: 18, size: size))
        XCTAssertTrue(first === FrameOverlayRenderer.makeTextImage("Hello", fontSize: 18, size: size))
        let changed = [
            FrameOverlayRenderer.makeTextImage("World", fontSize: 18, size: size),
            FrameOverlayRenderer.makeTextImage("Hello", fontSize: 18, size: size, foregroundHex: "#FF0000"),
            FrameOverlayRenderer.makeTextImage("Hello", fontSize: 24, size: size),
            FrameOverlayRenderer.makeTextImage("Hello", fontSize: 18, size: CGSize(width: 100, height: 50))
        ]
        for image in changed {
            let value = try XCTUnwrap(image)
            XCTAssertFalse(first === value)
            XCTAssertNotEqual(first.dataProvider?.data as Data?, value.dataProvider?.data as Data?)
        }
    }

    func test_rasterCache_enforcesByteBudgetAndDoesNotCacheFailuresOrOversizedImages() throws {
        let image = try XCTUnwrap(FrameOverlayRenderer.makeTextImage("Cache", fontSize: 18,
            size: CGSize(width: 100, height: 30)))
        let cache = OverlayRasterCache(byteLimit: image.bytesPerRow * image.height, countLimit: 2)
        let a = OverlayRasterCache.Key.text("a", fontSize: 1, width: 1, height: 1, color: "#FFFFFF")
        let b = OverlayRasterCache.Key.text("b", fontSize: 1, width: 1, height: 1, color: "#FFFFFF")
        var count = 0
        func create() -> CGImage? { count += 1; return image }
        _ = cache.image(for: a, create: create)
        _ = cache.image(for: a, create: create)
        XCTAssertEqual(count, 1)
        _ = cache.image(for: b, create: create)
        _ = cache.image(for: a, create: create)
        XCTAssertEqual(count, 3)
        let small = OverlayRasterCache(byteLimit: 1)
        _ = small.image(for: a, create: create)
        _ = small.image(for: a, create: create)
        XCTAssertEqual(count, 5)
        let failed = OverlayRasterCache()
        XCTAssertNil(failed.image(for: a) { nil })
        XCTAssertNotNil(failed.image(for: a, create: create))
    }

    func test_spotlightRaster_changedRegionAndOpacityChangeRenderedPixels() {
        let frame = CGRect(x: 0, y: 0, width: 64, height: 48)
        let context = CIContext()
        func pixels(x: Double, opacity: Double) -> [UInt8] {
            var project = DemoProject(name: "Raster",
                effects: [.spotlight(SpotlightEffect(startTime: 0, endTime: 1,
                    x: x, y: 0.25, width: 0.25, height: 0.5, dimOpacity: opacity))])
            project.theme.showsBranding = false
            let result = FrameOverlayRenderer.compositeFrameOverlays(project: project,
                over: CIImage(color: .white).cropped(to: frame),
                at: CMTime(seconds: 0.5, preferredTimescale: 600), frame: frame)
            var bytes = [UInt8](repeating: 0, count: 64 * 48 * 4)
            bytes.withUnsafeMutableBytes {
                context.render(result, toBitmap: $0.baseAddress!, rowBytes: 64 * 4,
                    bounds: frame, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            }
            return bytes
        }
        let original = pixels(x: 0.125, opacity: 0.6)
        XCTAssertEqual(original, pixels(x: 0.125, opacity: 0.6))
        let moved = pixels(x: 0.625, opacity: 0.6)
        XCTAssertNotEqual(original, moved)
        XCTAssertGreaterThan(original[(24 * 64 + 12) * 4], moved[(24 * 64 + 12) * 4])
        XCTAssertNotEqual(original, pixels(x: 0.125, opacity: 0.3))
    }
}
