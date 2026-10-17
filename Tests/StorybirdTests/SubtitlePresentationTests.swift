import AppKit
import CoreImage
import CoreMedia
import StorybirdCore
import SwiftUI
@testable import Storybird
import XCTest

@MainActor
final class SubtitlePresentationTests: XCTestCase {
    func test_wordWrapping_preservesEnglishWordsAndKoreanEojeolAtOneSize() throws {
        let size = CGSize(width: 360, height: 720)
        let style = TextOverlayStyle(fontSize: 28)
        for text in [
            "Every requested word including the final sentence must remain visible in the exported video.",
            "자막의 글자 크기는 일정하게 유지하고 모든 문구를 빠짐없이 표시합니다. 마지막 문장도 보존합니다.",
        ] {
            let layout = try SubtitleTextRenderer.layout(text: text, style: style, frameSize: size)
            XCTAssertGreaterThan(layout.lines.count, 1)
            XCTAssertEqual(layout.lines.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) },
                           text.split(whereSeparator: \.isWhitespace).map(String.init))
            let short = try SubtitleTextRenderer.layout(text: "Short", style: style, frameSize: size)
            XCTAssertEqual(layout.fontSize, short.fontSize)
            let width = VideoOverlayMetrics(frameSize: size).subtitleMaximumWidth - layout.horizontalPadding * 2
            XCTAssertTrue(layout.lines.allSatisfy { $0.width <= width })
        }
    }

    func test_safeWidth_usesWideFrameRatherThanFixedColumn() throws {
        let size = CGSize(width: 1920, height: 1080)
        let metrics = VideoOverlayMetrics(frameSize: size)
        XCTAssertEqual(metrics.subtitleMaximumWidth, size.width - metrics.subtitleInset * 2)
        let text = Array(repeating: "Full width subtitles", count: 7).joined(separator: " ")
        let layout = try SubtitleTextRenderer.layout(text: text, style: .default, frameSize: size)
        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertGreaterThan(layout.size.width, 1140, "Previously limited to 760 × 1.5 pixels.")
    }

    func test_multilineRaster_drawsEveryLineIncludingTextAfterThirdLine() throws {
        let text = (1...6).map { "Line \($0) complete text 자막" }.joined(separator: "\n")
        let size = CGSize(width: 640, height: 480)
        let layout = try SubtitleTextRenderer.layout(text: text, style: .default, frameSize: size)
        XCTAssertEqual(layout.lines.count, 6)
        XCTAssertEqual(layout.lines.map(\.text).joined(separator: "\n"), text)
        let image = try SubtitleTextRenderer.image(text: text, style: .default, frameSize: size)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Equal line heights permit checking every actual glyph band in either
        // bitmap row orientation. A three-line ceiling leaves empty bands.
        let lineHeight = try XCTUnwrap(layout.lines.first?.height)
        for lineIndex in 0..<6 {
            let firstRow = Int(layout.verticalPadding + CGFloat(lineIndex) * lineHeight)
            let lastRow = min(bitmap.pixelsHigh, Int(layout.verticalPadding + CGFloat(lineIndex + 1) * lineHeight))
            var whitePixels = 0
            for y in firstRow..<lastRow {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > 0.8, color.greenComponent > 0.8, color.blueComponent > 0.8 {
                        whitePixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(whitePixels, 20, "Line \(lineIndex + 1) must contain rendered glyphs.")
        }
    }

    func test_overflow_reportsLayerWithoutMutatingTextOrSize() throws {
        XCTAssertThrowsError(try SubtitleTextRenderer.layout(text: "Keep", style: TextOverlayStyle(fontSize: 1e308),
                                                            frameSize: CGSize(width: 640, height: 480)))
        for text in [String(repeating: "가", count: 100), Array(repeating: "Complete line", count: 100).joined(separator: "\n")] {
            var project = DemoProject(name: "Overflow", recording: VideoRecordingAsset(
                filename: "synthetic.mp4", duration: 2, width: 640, height: 480))
            project.subtitles = [TimedSubtitle(startTime: 0, endTime: 1, text: text)]
            let before = project
            XCTAssertThrowsError(try LayeredVideoExporter.validateForExport(project)) { error in
                XCTAssertTrue(error.localizedDescription.contains(project.subtitles[0].id.uuidString))
            }
            XCTAssertEqual(project, before)
            XCTAssertNoThrow(try SubtitleTextRenderer.validate(project, at: 1.5), "Inactive subtitle must not block another frame.")
            var cue = TimedPointerClick(time: 0.5, x: 0.5, y: 0.5, caption: "Click")
            cue.cueSubtitle.text = text
            project.subtitles = []
            project.clicks = [cue]
            XCTAssertThrowsError(try LayeredVideoExporter.validateForExport(project)) { error in
                XCTAssertTrue(error.localizedDescription.contains(cue.id.uuidString))
            }
        }
    }

    func test_explicitNewlines_preserveEmptyParagraphAndFontAcrossPreviewScales() throws {
        let text = "First paragraph\n\n두 번째 문단\r\nLast paragraph"
        let size = CGSize(width: 1920, height: 1080)
        let layout = try SubtitleTextRenderer.layout(text: text, style: .default, frameSize: size)
        XCTAssertEqual(layout.lines.map(\.text), ["First paragraph", "", "두 번째 문단", "Last paragraph"])
        for width in [480.0, 960.0] {
            let metrics = VideoOverlayMetrics(frameSize: CGSize(width: width, height: width * 9 / 16), renderSize: size)
            XCTAssertEqual(VideoOverlayPresentation.fontSize(style: .default, metrics: metrics),
                           layout.fontSize * width / size.width, accuracy: 0.001)
        }
    }

    func test_nativeOverlayOrder_keepsSpotlightBelowBothCaptionsAndIndependentAboveCue() throws {
        var project = DemoProject(name: "Overlay order", recording: VideoRecordingAsset(
            filename: "synthetic.mp4", duration: 3, width: 640, height: 480))
        project.theme.showsBranding = false
        var cue = TimedPointerClick(time: 0.5, x: 0.5, y: 0.5)
        cue.indicator.opacity = 0
        cue.cueSubtitle.text = "Visible caption"
        cue.cueSubtitle.style.foregroundHex = "#FF0000"
        project.clicks = [cue]
        project.subtitles = [TimedSubtitle(startTime: 0, endTime: 2, text: "Visible caption",
            style: TextOverlayStyle(backgroundOpacity: 0, foregroundHex: "#00FF00"))]
        project.effects = [.spotlight(SpotlightEffect(startTime: 0, endTime: 2, x: 0.1, y: 0.1,
            width: 0.2, height: 0.2, dimOpacity: 0.8))]
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            VideoSpotlightCanvas(project: project, time: 1, imageFrame: frame)
            VideoOverlayCanvas(project: project, time: 1, imageFrame: frame)
            VideoScreenOverlayCanvas(project: project, time: 1, imageFrame: frame)
        }.frame(width: 640, height: 480))
        renderer.scale = 1
        let native = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let output = try FrameOverlayRenderer.compositeFrameOverlays(project: project,
            over: CIImage(color: .white).cropped(to: frame), at: CMTime(seconds: 1, preferredTimescale: 600), frame: frame)
        let expected = NSBitmapImageRep(cgImage: try XCTUnwrap(CIContext().createCGImage(output, from: frame)))
        var actualMask = Set<Int>(), expectedMask = Set<Int>()
        for y in 390..<480 {
            for x in 0..<640 {
                let a = try XCTUnwrap(native.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if (a.greenComponent > 0.5 && a.greenComponent - a.redComponent > 0.3) { actualMask.insert(y * 640 + x) }
                if (b.greenComponent > 0.5 && b.greenComponent - b.redComponent > 0.3) { expectedMask.insert(y * 640 + x) }
            }
        }
        XCTAssertGreaterThan(expectedMask.count, 100)
        XCTAssertGreaterThan(actualMask.count, 100)
        // Different compositors antialias the same glyph edge differently. Every
        // lit pixel must have a counterpart within one pixel in both directions;
        // dimming or drawing the red Cue last removes the green glyph entirely.
        for (mask, other) in [(actualMask, expectedMask), (expectedMask, actualMask)] {
            let missing = mask.filter { pixel in
                !(-1...1).contains { dy in (-1...1).contains { dx in other.contains(pixel + dy * 640 + dx) } }
            }
            XCTAssertTrue(missing.isEmpty, "Glyph pixels differ beyond a one-pixel antialias edge: \(missing.count)")
        }
    }

    func test_nativeContentOverlays_cropToCanvasWhenFillMovesSourceOutsideIt() throws {
        var project = DemoProject(name: "Crop overlays", recording: VideoRecordingAsset(filename: "source.mp4", duration: 3, width: 1280, height: 720))
        project.canvas.preset = .portrait
        project.clips[0].placement.mode = .fill
        var cue = TimedPointerClick(time: 0.5, x: 0.2, y: 0.5)
        cue.indicator.colorHex = "#FFFFFF"
        cue.indicator.size = 5
        project.clicks = [cue]
        project.effects = [.spotlight(SpotlightEffect(startTime: 0, endTime: 2, x: 0.1, y: 0.1, width: 0.2, height: 0.6))]
        let frame = CGRect(x: 100, y: 0, width: 225, height: 400)
        let renderer = ImageRenderer(content: ZStack {
            Color(red: 0, green: 0, blue: 1)
            VideoSpotlightCanvas(project: project, time: 1, imageFrame: frame)
            VideoOverlayCanvas(project: project, time: 1, imageFrame: frame)
        }.frame(width: 425, height: 400))
        renderer.scale = 1
        let pixels = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let background = ImageRenderer(content: Color(red: 0, green: 0, blue: 1).frame(width: 425, height: 400))
        background.scale = 1
        let reference = NSBitmapImageRep(cgImage: try XCTUnwrap(background.cgImage))
        let expected = try XCTUnwrap(reference.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        var leaked = 0
        for y in 0..<400 { for x in 0..<95 {
            let color = try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if abs(color.blueComponent - expected.blueComponent) > 0.001
                || abs(color.redComponent - expected.redComponent) > 0.001
                || abs(color.greenComponent - expected.greenComponent) > 0.001 { leaked += 1 }
        } }
        XCTAssertEqual(leaked, 0, "Content overlays must be cropped to the output canvas, including the spotlight hole.")
    }

    func test_nativeBranding_usesTheOutputRasterAndCanvasCorner() throws {
        let project = DemoProject(name: "Branding", recording: VideoRecordingAsset(filename: "test.mp4", duration: 1, width: 640, height: 480))
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let renderer = ImageRenderer(content: VideoScreenOverlayCanvas(project: project, time: 0.5, imageFrame: frame)
            .frame(width: 640, height: 480).background(.black))
        renderer.scale = 1
        let native = try XCTUnwrap(renderer.cgImage)
        let output = try FrameOverlayRenderer.compositeFrameOverlays(project: project,
            over: CIImage(color: .black).cropped(to: frame), at: CMTime(seconds: 0.5, preferredTimescale: 600), frame: frame)
        let expected = try XCTUnwrap(CIContext().createCGImage(output, from: frame))
        // The small mark shares its text raster. Compare its weighted position
        // and ink area so different antialiasing of tiny glyphs is not mistaken
        // for a different font or corner placement.
        func ink(_ image: CGImage) throws -> (x: Double, y: Double, weight: Double) {
            let pixels = NSBitmapImageRep(cgImage: image)
            var weight = 0.0, xSum = 0.0, ySum = 0.0
            for y in 440..<480 { for x in 400..<640 {
                let color = try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let value = Double(color.redComponent)
                weight += value; xSum += Double(x) * value; ySum += Double(y) * value
            } }
            return (xSum / weight, ySum / weight, weight)
        }
        let actual = try ink(native), reference = try ink(expected)
        XCTAssertGreaterThan(actual.weight, 10)
        XCTAssertEqual(actual.x, reference.x, accuracy: 1)
        XCTAssertEqual(actual.y, reference.y, accuracy: 1)
        print("BRANDING_INK_RATIO", actual.weight / reference.weight)
        // Ink energy is diagnostic only: the platform's glyph antialiasing is
        // not a contract requiring byte-identical preview/export text colors.
    }

    func test_nativeSubtitlePreview_matchesSharedRasterAtBothAnchors() throws {
        var project = DemoProject(name: "Subtitle preview", recording: VideoRecordingAsset(
            filename: "synthetic.mp4", duration: 2, width: 640, height: 480))
        project.theme.showsBranding = false
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        for position in [SubtitlePosition.top, .bottom] {
            project.subtitles = [TimedSubtitle(startTime: 0, endTime: 1,
                text: "첫째 줄\nSecond line\n셋째 줄\nFinal complete line", position: position)]
            let renderer = ImageRenderer(content: VideoScreenOverlayCanvas(project: project, time: 0.5, imageFrame: frame)
                .frame(width: 640, height: 480).background(.black))
            renderer.scale = 1
            let native = try XCTUnwrap(renderer.cgImage)
            let output = try FrameOverlayRenderer.compositeFrameOverlays(project: project,
                over: CIImage(color: .black).cropped(to: frame), at: CMTime(seconds: 0.5, preferredTimescale: 600), frame: frame)
            let expected = try XCTUnwrap(CIContext().createCGImage(output, from: frame))
            // Color management may shift antialiased edge pixels; compare the
            // glyph/position mask instead of asserting byte-identical colors.
            let actualPixels = NSBitmapImageRep(cgImage: native)
            let expectedPixels = NSBitmapImageRep(cgImage: expected)
            var mismatches = 0
            var glyphs = 0
            for y in 0..<480 {
                for x in 0..<640 {
                    let actual = (actualPixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5
                    let expected = (expectedPixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5
                    if actual != expected { mismatches += 1 }
                    if expected { glyphs += 1 }
                }
            }
            XCTAssertGreaterThan(glyphs, 100)
            XCTAssertLessThan(mismatches, 100, "Native and output glyphs must occupy the same pixels (\(position)).")
        }
    }
}
