import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class TimelineLayerDragTests: XCTestCase {
    func test_layerRows_giveEveryClickSubtitleAudioAndEffectItsOwnRow() throws {
        var project = fixture()
        for index in 0..<12 {
            project.subtitles.append(TimedSubtitle(startTime: 2, endTime: 4, text: "Overlap \(index)"))
        }
        project = try VideoTimelineEditor.addClickCue(to: project, at: 2, x: 0.5, y: 0.5)
        project = try VideoTimelineEditor.addClickCue(to: project, at: 2, x: 0.2, y: 0.2)
        project.narrations = (0..<3).map {
            NarrationClip(filename: "audio-\($0).wav", text: "", startTime: 2, duration: 2, name: "Audio \($0)")
        }
        project.effects = [
            .spotlight(SpotlightEffect(startTime: 2, endTime: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
            .panZoom(PanZoomEffect(startTime: 2, endTime: 4, endX: 0.5, endY: 0.5, endScale: 1.5))
        ]
        let rows = TimelineTrackLayout.rows(in: project)
        let editable = rows.filter { $0.kind != .video && $0.kind != .suggestion }
        XCTAssertTrue(editable.allSatisfy { $0.spans.count == 1 })
        XCTAssertEqual(rows.filter { $0.kind == .subtitle }.count, project.subtitles.count)
        XCTAssertEqual(rows.filter { $0.kind == .click }.count, 2)
        XCTAssertEqual(rows.filter { $0.kind == .narration }.count, 3)
        XCTAssertEqual(rows.filter { $0.kind == .effect }.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows.first?.spans.count, project.clips.count)
    }

    func test_drag_manyPreviewUpdatesPublishOnceAndUndoOnceRestoresOriginal() throws {
        let store = try storeFixture()
        let project = try XCTUnwrap(store.projects.first)
        let id = project.subtitles[0].id
        let model = TimelineLayerDragModel()
        for translation in [10.0, 20, 50, 100] {
            model.update(target: .subtitle(id), translation: translation, canvasWidth: 1000, project: project)
            XCTAssertEqual(store.project(id: project.id), project)
        }
        XCTAssertEqual(model.delta, 2)
        model.finish(in: store)
        let moved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(moved.subtitles[0].startTime, 4)
        XCTAssertEqual(moved.subtitles[0].endTime, 6)
        XCTAssertEqual(moved.revision, project.revision + 1)
        XCTAssertNil(model.target)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.subtitles, project.subtitles)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        _ = try store.redo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.subtitles, moved.subtitles)
    }

    func test_drag_staleRevisionDoesNotOverwriteConcurrentEdit() throws {
        let store = try storeFixture()
        let project = try XCTUnwrap(store.projects.first)
        let model = TimelineLayerDragModel()
        model.update(target: .subtitle(project.subtitles[0].id), translation: 100, canvasWidth: 1000, project: project)
        var current = project
        current.subtitles[0].text = "Concurrent edit"
        let saved = try store.saveProject(current, expectedRevision: project.revision)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), saved)
        XCTAssertNotNil(store.errorMessage)
        _ = try store.undo(projectID: project.id)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_drag_preservesConcurrentSuggestionChangeWithoutRevisionIncrement() throws {
        let store = try storeFixture()
        let initial = try XCTUnwrap(store.projects.first)
        let withClick = try VideoTimelineEditor.addClickCue(to: initial, at: 7, x: 0.5, y: 0.5)
        let baseline = try store.saveProject(withClick, expectedRevision: initial.revision)
        let model = TimelineLayerDragModel()
        model.update(
            target: .subtitle(baseline.subtitles[0].id), translation: 100,
            canvasWidth: 1000, project: baseline
        )
        var concurrent = baseline
        concurrent.suggestions[0].spotlight.dimOpacity = 0.3
        let saved = try store.saveProject(concurrent, expectedRevision: baseline.revision)
        XCTAssertEqual(saved.revision, baseline.revision)

        model.finish(in: store)

        let moved = try XCTUnwrap(store.project(id: baseline.id))
        XCTAssertEqual(moved.subtitles[0].startTime, 4)
        XCTAssertEqual(moved.revision, baseline.revision + 1)
        XCTAssertEqual(moved.suggestions, saved.suggestions)
        _ = try store.undo(projectID: baseline.id)
        XCTAssertEqual(store.project(id: baseline.id)?.suggestions, saved.suggestions)
    }

    func test_drag_invalidMoveAndCancellationLeaveNoUndoEntry() throws {
        let store = try storeFixture()
        let project = try XCTUnwrap(store.projects.first)
        let model = TimelineLayerDragModel()
        model.update(target: .subtitle(project.subtitles[0].id), translation: -200, canvasWidth: 1000, project: project)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        model.update(target: .subtitle(project.subtitles[0].id), translation: 100, canvasWidth: 1000, project: project)
        model.cancel()
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_drag_writeFailureRestoresStoredTimesAndUndoState() throws {
        let store = try storeFixture()
        let project = try XCTUnwrap(store.projects.first)
        let library = store.repository.rootURL.appendingPathComponent("library.json")
        let backup = library.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: library, to: backup)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let model = TimelineLayerDragModel()
        model.update(target: .subtitle(project.subtitles[0].id), translation: 100, canvasWidth: 1000, project: project)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: backup, to: library)
        XCTAssertEqual(try store.repository.loadProjects(), [project])
    }

    func test_timelineUI_dragCommitsAndVerticalScrollReachesLastLayer() async throws {
        let store = try storeFixture()
        let original = try XCTUnwrap(store.projects.first)
        let url = store.repository.assetURL(projectID: original.id, filename: "synthetic.mp4")
        _ = try await TestVideoFactory.makeMovie(at: url, includeAudio: false, duration: 20)
        var project = original
        project.subtitles += (1...15).map {
            TimedSubtitle(startTime: 2, endTime: 4, text: "Overlapping subtitle \($0)")
        }
        try store.saveProject(project, expectedRevision: original.revision)

        for width in [1100.0, 760.0] {
            let view = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: project.id)
                .frame(width: width, height: 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(400))
            view.layoutSubtreeIfNeeded()
            try snapshot(view, name: "timeline-\(Int(width))-before")
            let canvasScroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView else { return false }
                return document.bounds.width >= 960 && document.bounds.height > 800
            })
            let canvas = try XCTUnwrap(canvasScroll.documentView)
            if width == 1100 {
                let before = try XCTUnwrap(store.project(id: project.id))
                // The synthetic subtitle spans 2–4 seconds; its center is at
                // x=144 on the 48-point/second ruler and y=139 on the third row.
                let start = canvas.convert(NSPoint(x: 144, y: canvas.isFlipped ? 139 : canvas.bounds.height - 139), to: nil)
                sendMouse(.leftMouseDown, at: start, in: window)
                for offset in [10.0, 30, 60, 96] {
                    sendMouse(.leftMouseDragged, at: NSPoint(x: start.x + offset, y: start.y), in: window)
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertEqual(store.project(id: project.id)?.revision, before.revision)
                sendMouse(.leftMouseUp, at: NSPoint(x: start.x + 96, y: start.y), in: window)
                try await Task.sleep(for: .milliseconds(200))
                let after = try XCTUnwrap(store.project(id: project.id))
                XCTAssertEqual(after.subtitles[0].startTime, 4, accuracy: 0.05)
                XCTAssertEqual(after.revision, before.revision + 1)
                try snapshot(view, name: "timeline-dragged")
            }
            let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView else { return false }
                return document.bounds.height > 800 && $0.contentSize.height < 500
            })
            let document = try XCTUnwrap(scroll.documentView)
            document.scroll(NSPoint(x: 0, y: document.isFlipped
                ? document.bounds.height - scroll.contentSize.height : 0))
            try await Task.sleep(for: .milliseconds(150))
            let finalRowRect = canvas.convert(
                NSRect(x: 96, y: canvas.isFlipped ? 784 : canvas.bounds.height - 822, width: 96, height: 38),
                to: scroll
            )
            XCTAssertTrue(scroll.bounds.intersects(finalRowRect), "The final subtitle must be reachable by vertical scroll.")
            let viewport = scroll.convert(scroll.bounds, to: view)
            XCTAssertTrue(view.bounds.contains(viewport), "The scroll viewport itself must fit inside the window: \(viewport) in \(view.bounds)")
            try snapshot(view, name: "timeline-\(Int(width))-scrolled")
        }
    }

    /// Sends events only to the synthetic host window, without posting global
    /// pointer input or requiring Accessibility permission.
    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        window.sendEvent(event)
    }

    /// Finds native scroll containers in a synthetic SwiftUI host.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Saves only synthetic timeline and scroll evidence to the build directory.
    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/timeline-layer-ui")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("\(name).png"))
    }

    /// Uses only generated metadata in a temporary library for publication and undo.
    private func storeFixture() throws -> AppStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storybird-drag-\(UUID().uuidString)")
        let repository = ProjectRepository(rootURL: root)
        try repository.saveProjects([fixture()])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return AppStore(repository: repository)
    }

    /// Keeps test times on a known twenty-second project clock.
    private func fixture() -> DemoProject {
        DemoProject(
            name: "Synthetic drag",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 20, width: 1280, height: 720),
            clips: [VideoClip(sourceStart: 0, sourceEnd: 10), VideoClip(sourceStart: 10, sourceEnd: 20)],
            subtitles: [TimedSubtitle(startTime: 2, endTime: 4, text: "Subtitle")]
        )
    }
}
