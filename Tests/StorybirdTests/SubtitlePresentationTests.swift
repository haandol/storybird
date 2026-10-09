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
