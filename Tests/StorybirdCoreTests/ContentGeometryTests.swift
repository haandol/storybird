import Foundation
import XCTest
@testable import StorybirdCore

final class ContentGeometryTests: XCTestCase {
    func test_fitFillAndAnchor_projectSourcePointsWithoutChangingStoredCoordinates() {
        var project = fixture()
        project.canvas.preset = .square
        XCTAssertEqual(ProjectContentGeometry.frame(in: project, at: 1), CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        let top = ProjectContentGeometry.point(x: 0, y: 0, in: project, at: 1)
        XCTAssertEqual(top, VideoNormalizedPoint(x: 0, y: 0.25))
        project.clips[0].placement = MediaPlacement(mode: .fill, anchorX: 0)
        XCTAssertEqual(ProjectContentGeometry.frame(in: project, at: 1), CGRect(x: 0, y: 0, width: 2, height: 1))
        project.clips[0].placement.anchorX = 1
        XCTAssertEqual(ProjectContentGeometry.frame(in: project, at: 1), CGRect(x: -1, y: 0, width: 2, height: 1))
        let click = TimedPointerClick(time: 1, x: 0.25, y: 0.5)
        let projected = ProjectContentGeometry.click(click, in: project, at: 1)
        XCTAssertEqual(projected.x, -0.5)
        XCTAssertEqual(click.x, 0.25)
    }

    func test_cameraSpotlightAndInverse_useOneCanvasProjection() {
        var project = fixture()
        project.canvas.preset = .square
        project.effects = [.panZoom(PanZoomEffect(startTime: 0, endTime: 2,
            startX: 0.25, startY: 0.5, startScale: 2, endX: 0.25, endY: 0.5, endScale: 2))]
        let camera = VideoOverlayPresentation.camera(in: project, at: 1)
        XCTAssertEqual(camera, VideoCameraPresentation(x: 0.25, y: 0.5, scale: 2))
        let projected = ProjectContentGeometry.spotlight(SpotlightEffect(startTime: 0, endTime: 2,
            x: 0.2, y: 0.4, width: 0.1, height: 0.2), in: project, at: 1)
        XCTAssertEqual(projected.x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(projected.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(projected.height, 0.2, accuracy: 1e-9)
        let original = ProjectContentGeometry.sourcePoint(canvasX: projected.x, canvasY: projected.y,
            frame: ProjectContentGeometry.frame(in: project, at: 1), camera: camera)
        XCTAssertEqual(original.x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(original.y, 0.4, accuracy: 1e-9)
    }

    func test_canvasPresets_keepPrimaryReferenceAndExactPixels() {
        var project = fixture()
        project.mediaAssets = [ProjectMediaAsset(kind: .image, filename: "picture.png", name: "Picture", width: 20, height: 40)]
        for (preset, size) in [(ProjectCanvas.Preset.original, CGSize(width: 200, height: 100)),
            (.landscape, CGSize(width: 1920, height: 1080)), (.portrait, CGSize(width: 1080, height: 1920)),
            (.square, CGSize(width: 1080, height: 1080))] {
            project.canvas.preset = preset
            XCTAssertEqual(project.canvasSize, size)
        }
        XCTAssertEqual(project.recording?.width, 200)
        XCTAssertEqual(project.recording?.height, 100)
    }

    private func fixture() -> DemoProject {
        DemoProject(name: "Projection", recording: VideoRecordingAsset(filename: "video.mp4", duration: 2, width: 200, height: 100))
    }
}
