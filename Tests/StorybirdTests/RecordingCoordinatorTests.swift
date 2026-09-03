import AppKit
import CoreGraphics
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func test_recordingHUDLayout_centersPanelBelowVisibleTop() {
        let origin = RecordingHUDLayout.initialOrigin(
            panelSize: CGSize(width: 330, height: 74),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_440, height: 900)
        )

        XCTAssertEqual(origin.x, 655)
        XCTAssertEqual(origin.y, 780)
    }

    func test_recordingHUDLayout_shortVisibleFrame_keepsPanelInsideBottom() {
        let origin = RecordingHUDLayout.initialOrigin(
            panelSize: CGSize(width: 330, height: 74),
            visibleFrame: CGRect(x: 0, y: 25, width: 1_200, height: 140)
        )

        XCTAssertEqual(origin.x, 435)
        XCTAssertEqual(origin.y, 25)
    }

    func test_clickIngress_freezesCoordinatesAgainstAcceptedCaptureFrame() throws {
        let ingress = RecordedClickIngress()
        let image = try makeImage()
        ingress.start()

        let accepted = ingress.accept(
            screenPoint: CGPoint(x: 500, y: 250),
            captureFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            screenImage: image
        )

        let click = try XCTUnwrap(ingress.takeAcceptedClicks().first)
        XCTAssertTrue(accepted)
        XCTAssertEqual(click.normalizedPoint.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(click.normalizedPoint.y, 0.25, accuracy: 0.001)
        XCTAssertTrue(click.screenImage === image)
    }

    func test_clickIngress_preservesOrderAndRejectsClicksAfterStop() throws {
        let ingress = RecordedClickIngress()
        let image = try makeImage()
        ingress.start()

        XCTAssertTrue(
            ingress.accept(
                screenPoint: CGPoint(x: 10, y: 10),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                screenImage: image
            )
        )
        XCTAssertTrue(
            ingress.accept(
                screenPoint: CGPoint(x: 20, y: 20),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                screenImage: image
            )
        )

        ingress.stopAccepting()

        XCTAssertFalse(
            ingress.accept(
                screenPoint: CGPoint(x: 30, y: 30),
                captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                screenImage: image
            )
        )
        let clicks = ingress.takeAcceptedClicks()
        XCTAssertEqual(clicks.map(\.normalizedPoint.x), [0.1, 0.2])
        XCTAssertEqual(clicks.map(\.normalizedPoint.y), [0.1, 0.2])
    }

    func test_clickProcessor_drainsTwoClicksInOrderBeforeStopReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Ordered recording")
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let firstStepID = try store.beginRecordedFlow(
            with: image(color: .red),
            in: project.id
        )
        var resultImages = [
            try cgImage(color: .blue),
            try cgImage(color: .yellow),
        ]
        var savedCounts: [Int] = []
        var failures: [Error] = []
        let processor = RecordedClickProcessor(
            currentStepID: firstStepID,
            resultDelay: .zero,
            resultImageProvider: {
                resultImages.removeFirst()
            },
            persistClick: { click, resultingImage, sourceStepID in
                try store.appendRecordedClick(
                    at: click.normalizedPoint,
                    clickedImage: click.screenImage.storybirdTestImage,
                    resultingImage: resultingImage.storybirdTestImage,
                    from: sourceStepID,
                    in: project.id
                )
            },
            didUpdatePending: { _ in },
            didSaveClick: { savedCounts.append($0) },
            didFail: { failures.append($0) }
        )
        processor.enqueue(
            [
                RecordedClick(
                    normalizedPoint: CGPoint(x: 0.1, y: 0.2),
                    screenImage: try cgImage(color: .green)
                ),
                RecordedClick(
                    normalizedPoint: CGPoint(x: 0.3, y: 0.4),
                    screenImage: try cgImage(color: .cyan)
                ),
            ]
        )

        await processor.stopAndDrain()

        let updated = try XCTUnwrap(store.project(id: project.id))
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(savedCounts, [1, 2])
        XCTAssertEqual(updated.steps.count, 3)
        XCTAssertEqual(
            updated.steps[0].hotspots.first?.targetStepID,
            updated.steps[1].id
        )
        XCTAssertEqual(
            updated.steps[1].hotspots.first?.targetStepID,
            updated.steps[2].id
        )
        XCTAssertEqual(updated.steps[0].hotspots.first?.x, 0.1)
        XCTAssertEqual(updated.steps[1].hotspots.first?.x, 0.3)
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }

    private func image(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
    }

    private func cgImage(color: NSColor) throws -> CGImage {
        let image = image(color: color)
        return try XCTUnwrap(
            image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
    }
}

private extension CGImage {
    var storybirdTestImage: NSImage {
        NSImage(
            cgImage: self,
            size: NSSize(width: width, height: height)
        )
    }
}
