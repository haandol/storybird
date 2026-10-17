import Foundation
import XCTest
@testable import StorybirdCore

final class VisualMediaModelTests: XCTestCase {
    func test_legacyProjectJSON_preservesClipsAndDefaultsNewVisualFields() throws {
        let project = DemoProject(name: "Legacy", recording: VideoRecordingAsset(
            filename: "source.mp4", duration: 2, width: 320, height: 180))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "mediaAssets")
        json.removeValue(forKey: "canvas")
        var clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
        for index in clips.indices { clips[index].removeValue(forKey: "placement"); clips[index].removeValue(forKey: "mediaAssetID") }
        json["clips"] = clips
        let decoded = try JSONDecoder().decode(DemoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.clips, project.clips)
        XCTAssertEqual(decoded.canvas, ProjectCanvas())
        XCTAssertTrue(decoded.mediaAssets.isEmpty)
        XCTAssertEqual(decoded.availableMediaAssets.first?.id, project.id)
        XCTAssertEqual(decoded.mediaAsset(for: decoded.clips[0])?.filename, "source.mp4")
    }

    func test_mediaPlacement_usesOwnedDurationAndRejectsForeignAndInvalidReferences() throws {
        var project = DemoProject(name: "Assets", recording: VideoRecordingAsset(
            filename: "source.mp4", duration: 1, width: 320, height: 180))
        let movie = ProjectMediaAsset(kind: .video, filename: "second.mp4", name: "Second", width: 100, height: 200, duration: 5)
        let image = ProjectMediaAsset(kind: .image, filename: "image.png", name: "Image", width: 20, height: 40, hasAudio: false)
        project.mediaAssets = [movie, image]
        let video = try MediaAssetEditor.place(assetID: movie.id, in: project, destination: 1, sourceStart: 3, sourceEnd: 4)
        XCTAssertEqual(video.clips.last?.mediaAssetID, movie.id)
        XCTAssertEqual(video.timelineDuration, 2)
        let picture = try MediaAssetEditor.place(assetID: image.id, in: video, destination: 1, duration: 0.5)
        XCTAssertEqual(picture.clips[1].kind, .image)
        XCTAssertEqual(picture.timelineDuration, 2.5)
        let foreignID = UUID()
        XCTAssertThrowsError(try MediaAssetEditor.place(assetID: foreignID, in: project, destination: 0)) {
            XCTAssertEqual($0 as? VideoProjectValidationError, .invalidMediaAsset(foreignID))
        }
        XCTAssertThrowsError(try MediaAssetEditor.place(assetID: image.id, in: project, destination: 0))
        XCTAssertThrowsError(try MediaAssetEditor.place(assetID: image.id, in: project, destination: 0, duration: -.infinity))
        XCTAssertThrowsError(try MediaAssetEditor.place(assetID: movie.id, in: project, destination: 0, sourceEnd: 6))
        XCTAssertEqual(project.clips.count, 1)
    }

    func test_canvasFitAndFill_preserveAspectAndNormalizeAlignment() {
        let source = CGSize(width: 200, height: 100), canvas = CGSize(width: 100, height: 100)
        XCTAssertEqual(MediaPlacement().frame(source: source, canvas: canvas), CGRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertEqual(MediaPlacement(mode: .fill, anchorX: 0).frame(source: source, canvas: canvas), CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(MediaPlacement(mode: .fill, anchorX: 1).frame(source: source, canvas: canvas), CGRect(x: -100, y: 0, width: 200, height: 100))
        XCTAssertFalse(MediaPlacement(anchorX: .nan).isValid)
    }

    func test_clipInsertion_keepsCTAAtEndWithoutChangingCardLength() throws {
        var project = DemoProject(name: "CTA", recording: VideoRecordingAsset(
            filename: "source.mp4", duration: 1, width: 320, height: 180))
        project = try DemoEffectEditor.insertCTA(in: project, duration: 0.5)
        let placed = try MediaAssetEditor.place(assetID: project.id, in: project, destination: 1)
        XCTAssertEqual(placed.effects.first?.startTime, 2)
        XCTAssertEqual(placed.effects.first?.endTime, 2.5)
        XCTAssertEqual(placed.timelineDuration, 2.5)
    }
}
