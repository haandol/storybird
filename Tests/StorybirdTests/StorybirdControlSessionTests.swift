import AppKit
import Foundation
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

final class StorybirdControlSessionTests: XCTestCase {
    func test_click_thenStop_returnsTimedVideoProjectPayload() async throws {
        let projectID = UUID()
        let output = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let platform = FakeDesktopPlatform()
        let session = StorybirdControlSession(platform: platform)

        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: projectID,
            projectName: "CDE video",
            recordingFilename: output.lastPathComponent,
            outputURL: output
        )
        _ = try await session.click(
            x: 0.2,
            y: 0.8,
            button: StorybirdMCPPointerButton.left
        )
        let completed = try await session.stopSession()

        XCTAssertEqual(completed.projectID, projectID)
        XCTAssertEqual(completed.projectName, "CDE video")
        XCTAssertEqual(completed.filename, output.lastPathComponent)
        XCTAssertEqual(completed.result.duration, 2)
        XCTAssertEqual(completed.result.width, 100)
        XCTAssertEqual(completed.result.height, 100)
        XCTAssertEqual(completed.clicks.count, 1)
        XCTAssertEqual(completed.clicks[0].time, 0.25)
        XCTAssertEqual(completed.clicks[0].x, 0.2)
        XCTAssertEqual(completed.clicks[0].y, 0.8)
        XCTAssertEqual(completed.clicks[0].button, .left)
    }

    func test_click_freshFrameUnavailable_stillRecordsPostedClickOnce() async throws {
        let output = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let session = StorybirdControlSession(
            platform: FakeDesktopPlatform(observedFreshFrame: false)
        )
        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: UUID(),
            projectName: "Stale frame",
            recordingFilename: output.lastPathComponent,
            outputURL: output
        )

        let outcome = try await session.click(
            x: 0.4,
            y: 0.6,
            button: .left
        )
        let completed = try await session.stopSession()

        XCTAssertFalse(outcome.observedFreshFrame)
        XCTAssertEqual(completed.clicks.count, 1)
        XCTAssertEqual(completed.clicks[0].x, 0.4)
        XCTAssertEqual(completed.clicks[0].y, 0.6)
    }

    func test_click_outsideSource_rejectsBeforeDesktopInput() async throws {
        let platform = FakeDesktopPlatform()
        let session = StorybirdControlSession(platform: platform)
        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: UUID(),
            projectName: "Video",
            recordingFilename: "recording.mp4",
            outputURL: URL(
                fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
            )
        )

        do {
            _ = try await session.click(
                x: 1.1,
                y: 0.5,
                button: StorybirdMCPPointerButton.left
            )
            XCTFail("Expected coordinate failure")
        } catch StorybirdMCPError.invalidCoordinate {
            let clicks = await platform.desktop.clicks()
            XCTAssertEqual(clicks, [])
        }
        await session.abort()
    }

    func test_concurrentClicks_areRecordedInAcceptedOrder() async throws {
        let output = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let platform = FakeDesktopPlatform(clickDelayMilliseconds: 40)
        let session = StorybirdControlSession(platform: platform)
        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: UUID(),
            projectName: "Ordered",
            recordingFilename: output.lastPathComponent,
            outputURL: output
        )

        let first = Task {
            try await session.click(
                x: 0.1,
                y: 0.2,
                button: StorybirdMCPPointerButton.left
            )
        }
        await Task.yield()
        let second = Task {
            try await session.click(
                x: 0.8,
                y: 0.7,
                button: StorybirdMCPPointerButton.right
            )
        }
        _ = try await first.value
        _ = try await second.value
        let completed = try await session.stopSession()

        let postedClicks = await platform.desktop.clicks()
        XCTAssertEqual(
            postedClicks,
            [
                RecordedPointerClick(x: 0.1, y: 0.2, button: .left),
                RecordedPointerClick(x: 0.8, y: 0.7, button: .right),
            ]
        )
        XCTAssertEqual(completed.clicks.map(\.button), [.left, .right])
        XCTAssertLessThan(completed.clicks[0].time, completed.clicks[1].time)
    }

    func test_stopSession_waitsForAcceptedInFlightClick() async throws {
        let output = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let session = StorybirdControlSession(
            platform: FakeDesktopPlatform(clickDelayMilliseconds: 80)
        )
        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: UUID(),
            projectName: "Drain",
            recordingFilename: output.lastPathComponent,
            outputURL: output
        )
        let click = Task {
            try await session.click(x: 0.3, y: 0.4, button: .left)
        }
        await Task.yield()
        let stop = Task {
            try await session.stopSession()
        }

        _ = try await click.value
        let completed = try await stop.value

        XCTAssertEqual(completed.clicks.count, 1)
        XCTAssertEqual(completed.clicks[0].x, 0.3)
    }

    func test_click_missingFrameBeforePost_recordsNoMetadata() async throws {
        let output = URL(
            fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"
        )
        let platform = FakeDesktopPlatform(clickFailsBeforePost: true)
        let session = StorybirdControlSession(platform: platform)
        _ = try await session.startSession(
            sourceID: "display-1",
            projectID: UUID(),
            projectName: "Missing frame",
            recordingFilename: output.lastPathComponent,
            outputURL: output
        )

        do {
            _ = try await session.click(x: 0.5, y: 0.5, button: .left)
            XCTFail("Expected no-frame failure")
        } catch StorybirdMCPError.noFrame {
            let completed = try await session.stopSession()
            let postedClicks = await platform.desktop.clicks()
            XCTAssertTrue(completed.clicks.isEmpty)
            XCTAssertTrue(postedClicks.isEmpty)
        }
    }

    func test_toolDefinitions_exposeVideoTimelineTools() {
        let tools = StorybirdMCPService.toolDefinitions
        XCTAssertEqual(
            tools.map(\.name),
            [
                "storybird_list_sources",
                "storybird_start_session",
                "storybird_observe",
                "storybird_move_pointer",
                "storybird_click",
                "storybird_scroll",
                "storybird_list_projects",
                "storybird_get_project",
                "storybird_replace_project",
                "storybird_split_clip",
                "storybird_trim_clip",
                "storybird_delete_clip",
                "storybird_move_clip",
                "storybird_set_clip_speed",
                "storybird_insert_freeze",
                "storybird_undo_project",
                "storybird_redo_project",
                "storybird_update_project",
                "storybird_update_click",
                "storybird_upsert_subtitle",
                "storybird_preview_project",
                "storybird_render_preview",
                "storybird_list_voice_profiles",
                "storybird_generate_narration",
                "storybird_update_narration",
                "storybird_delete_narration",
                "storybird_start_export",
                "storybird_get_export",
                "storybird_cancel_export",
                "storybird_export_project",
                "storybird_delete_project",
                "storybird_stop_session",
            ]
        )
        XCTAssertNotNil(tools.first { $0.name == "storybird_update_click" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_upsert_subtitle" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_replace_project" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_render_preview" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_start_export" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_get_export" })
        XCTAssertNotNil(tools.first { $0.name == "storybird_cancel_export" })
        XCTAssertNil(tools.first { $0.name == "storybird_update_step" })
        XCTAssertNil(tools.first { $0.name == "storybird_upsert_hotspot" })

        let click = tools.first { $0.name == "storybird_click" }
        let observe = tools.first { $0.name == "storybird_observe" }
        XCTAssertEqual(click?.annotations.destructiveHint, true)
        XCTAssertEqual(click?.annotations.openWorldHint, true)
        XCTAssertEqual(observe?.annotations.readOnlyHint, true)
    }

    func test_ipcClient_lostResponse_doesNotReplayPointerCommand() async {
        let sends = AsyncCounter()
        let launches = AsyncCounter()
        let client = StorybirdAppIPCClient(
            sender: { _ in
                _ = await sends.increment()
                throw StorybirdAppIPCStageError.resultUnknown("lost response")
            },
            launcher: {
                _ = await launches.increment()
            }
        )

        do {
            _ = try await client.call(
                name: "storybird_click",
                argumentsJSON: Data("{}".utf8)
            )
            XCTFail("Expected ambiguous response failure")
        } catch StorybirdAppIPCStageError.resultUnknown {
            let sendCount = await sends.value()
            let launchCount = await launches.value()
            XCTAssertEqual(sendCount, 1)
            XCTAssertEqual(launchCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_ipcClient_connectionFailure_launchesThenSendsOnce() async throws {
        let sends = AsyncCounter()
        let launches = AsyncCounter()
        let client = StorybirdAppIPCClient(
            sender: { _ in
                let attempt = await sends.increment()
                if attempt == 1 {
                    throw StorybirdAppIPCStageError.connectionUnavailable(
                        "not running"
                    )
                }
                return StorybirdControlResponse(text: "ok")
            },
            launcher: {
                _ = await launches.increment()
            }
        )

        let response = try await client.call(
            name: "storybird_observe",
            argumentsJSON: Data("{}".utf8)
        )

        XCTAssertEqual(response.text, "ok")
        let sendCount = await sends.value()
        let launchCount = await launches.value()
        XCTAssertEqual(sendCount, 2)
        XCTAssertEqual(launchCount, 1)
    }

    func test_mcpService_transportEnd_sendsInternalAbortCommand() async {
        let names = AsyncStringCollector()
        let client = StorybirdAppIPCClient(
            sender: { request in
                await names.append(request.name)
                return StorybirdControlResponse(text: "ok")
            },
            launcher: {}
        )
        let service = StorybirdMCPService(client: client)

        await service.abortActiveSession()

        let values = await names.values()
        XCTAssertEqual(values, ["storybird_abort_session"])
    }

    func test_orderedRequestGate_releasesAcceptedRequestsInSequence() async {
        let gate = StorybirdOrderedRequestGate()
        let order = AsyncIntCollector()
        let second = Task {
            await gate.wait(for: 1)
            await order.append(1)
            await gate.complete(1)
        }
        await Task.yield()
        let first = Task {
            await gate.wait(for: 0)
            await order.append(0)
            await gate.complete(0)
        }

        await first.value
        await second.value

        let values = await order.values()
        XCTAssertEqual(values, [0, 1])
    }

    func test_pointerGeometry_inclusiveMaximum_staysInsideQuartzFrame() throws {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 400)

        let point = try StorybirdPointerGeometry.screenPoint(
            x: 1,
            y: 1,
            frame: frame
        )

        XCTAssertTrue(frame.contains(point))
        XCTAssertLessThan(point.x, frame.maxX)
        XCTAssertLessThan(point.y, frame.maxY)
        XCTAssertGreaterThanOrEqual(point.x, frame.minX)
        XCTAssertGreaterThanOrEqual(point.y, frame.minY)
    }
}

private struct RecordedPointerClick: Equatable, Sendable {
    let x: Double
    let y: Double
    let button: StorybirdMCPPointerButton
}

private actor FakeDesktopSession: StorybirdDesktopSession {
    private let descriptor = StorybirdMCPSourceDescriptor(
        id: "display-1",
        kind: .display,
        title: "Test display",
        subtitle: "Entire screen",
        width: 100,
        height: 100
    )
    private let clickDelayMilliseconds: Int
    private let observedFreshFrame: Bool
    private let clickFailsBeforePost: Bool
    private var sequence: UInt64 = 1
    private var recordedClicks: [RecordedPointerClick] = []
    private var currentRecordingTime = 0.25

    init(
        clickDelayMilliseconds: Int,
        observedFreshFrame: Bool,
        clickFailsBeforePost: Bool
    ) {
        self.clickDelayMilliseconds = clickDelayMilliseconds
        self.observedFreshFrame = observedFreshFrame
        self.clickFailsBeforePost = clickFailsBeforePost
    }

    /// Returns the fixed source chosen by the fake platform.
    func sourceDescriptor() async -> StorybirdMCPSourceDescriptor {
        descriptor
    }

    /// Produces a valid PNG with a monotonic sequence for observation assertions.
    func latestFrame() async throws -> StorybirdMCPFrame {
        StorybirdMCPFrame(
            pngData: try Self.makePNG(color: .systemBlue),
            width: 2,
            height: 2
        )
    }

    /// Advances the fake frame after recording the visible pointer move.
    func movePointer(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws -> StorybirdMCPFrame {
        sequence += 1
        return try await latestFrame()
    }

    /// Records click order and advances the deterministic video clock.
    func click(
        x: Double,
        y: Double,
        button: StorybirdMCPPointerButton
    ) async throws -> StorybirdMCPClickResult {
        if clickFailsBeforePost {
            throw StorybirdMCPError.noFrame
        }
        if clickDelayMilliseconds > 0 {
            try await Task.sleep(
                for: .milliseconds(clickDelayMilliseconds)
            )
        }
        recordedClicks.append(
            RecordedPointerClick(x: x, y: y, button: button)
        )
        sequence += 1
        let result = StorybirdMCPClickResult(
            frame: StorybirdMCPFrame(
                pngData: try Self.makePNG(color: .systemGreen),
                width: 2,
                height: 2
            ),
            recordingTime: currentRecordingTime,
            observedFreshFrame: observedFreshFrame
        )
        currentRecordingTime += 0.25
        return result
    }

    /// Advances the frame for scroll without creating a click layer.
    func scroll(
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) async throws -> StorybirdMCPFrame {
        sequence += 1
        return try await latestFrame()
    }

    /// Returns a complete silent video result for project persistence tests.
    func stop() async throws -> StorybirdMCPVideoRecording {
        StorybirdMCPVideoRecording(
            duration: 2,
            width: 100,
            height: 100
        )
    }

    /// Has no external capture resource in the deterministic fake.
    func abort() async {}

    /// Exposes recorded input only to tests without sharing mutable storage.
    func clicks() -> [RecordedPointerClick] {
        recordedClicks
    }

    /// Encodes a tiny PNG accepted by the observation response.
    private static func makePNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                  using: .png,
                  properties: [:]
              )
        else {
            throw StorybirdMCPError.noFrame
        }
        return data
    }
}

private actor FakeDesktopPlatform: StorybirdDesktopPlatform {
    let desktop: FakeDesktopSession
    private var starts = 0

    init(
        clickDelayMilliseconds: Int = 0,
        observedFreshFrame: Bool = true,
        clickFailsBeforePost: Bool = false
    ) {
        desktop = FakeDesktopSession(
            clickDelayMilliseconds: clickDelayMilliseconds,
            observedFreshFrame: observedFreshFrame,
            clickFailsBeforePost: clickFailsBeforePost
        )
    }

    /// Lists the single deterministic source used by all session tests.
    func listSources() async throws -> [StorybirdMCPSourceDescriptor] {
        [await desktop.sourceDescriptor()]
    }

    /// Counts starts and rejects any source other than the fixture display.
    func startSession(
        sourceID: String,
        recordingURL: URL
    ) async throws -> any StorybirdDesktopSession {
        guard sourceID == "display-1",
              recordingURL.pathExtension == "mp4"
        else {
            throw StorybirdMCPError.sourceNotFound
        }
        starts += 1
        return desktop
    }

    /// Exposes how often consented capture was actually started.
    func startCount() -> Int {
        starts
    }
}

private actor AsyncCounter {
    private var count = 0

    /// Increments once and returns the new value for deterministic retry assertions.
    func increment() -> Int {
        count += 1
        return count
    }

    /// Returns the immutable count observed after an asynchronous call path.
    func value() -> Int {
        count
    }
}

private actor AsyncStringCollector {
    private var strings: [String] = []

    /// Appends one command name in call order for lifecycle assertions.
    func append(_ value: String) {
        strings.append(value)
    }

    /// Returns the immutable command sequence observed by the fake IPC sender.
    func values() -> [String] {
        strings
    }
}

private actor AsyncIntCollector {
    private var integers: [Int] = []

    /// Appends one accepted request sequence for ordering assertions.
    func append(_ value: Int) {
        integers.append(value)
    }

    /// Returns the immutable request order after the gate drains.
    func values() -> [Int] {
        integers
    }
}
