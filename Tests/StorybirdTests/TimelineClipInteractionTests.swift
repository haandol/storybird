import AppKit
import Foundation
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class TimelineClipInteractionTests: XCTestCase {
    private var mouseEventNumber = 0
    func test_nativeSelectionToolbar_deletesThroughVisibleButton() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = NSHostingView(rootView: TimelineBatchControls(store: store, project: project,
            targets: project.clips.map { ProjectEditReference(target: .clip, id: $0.id) }, playhead: 0,
            onSelect: { _ in }, onStyle: { _ in }, onProperties: { _ in })
            .frame(width: 700, height: 80, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 80),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try snapshot(view, name: "selection-toolbar-isolated")
        if let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
            window.makeFirstResponder(field)
            window.makeFirstResponder(nil)
        }
        click(NSPoint(x: 183, y: 70), window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id)?.clips.count, 0)
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
        XCTAssertEqual(try store.undo(projectID: project.id).clips, project.clips)
    }
    func test_clipGesture_previewCancelSnapAndStaleRevisionDoNotWrite() throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TimelineClipEditModel()
        let clip = project.clips[0]
        model.begin(clipID: clip.id, operation: .trimEnd, project: project, canvasWidth: 400, playhead: 2.5)
        model.update(translation: 48)
        XCTAssertEqual(model.guide, 2.5)
        XCTAssertTrue(model.previewSummary.contains("linked layers"))
        XCTAssertEqual(store.project(id: project.id), project)
        model.update(translation: 48, bypassSnap: true)
        XCTAssertNil(model.guide)
        model.cancel()
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        model.begin(clipID: clip.id, operation: .trimEnd, project: project, canvasWidth: 400, playhead: 0)
        model.update(translation: 50, bypassSnap: true)
        var concurrent = project
        concurrent.name = "Concurrent edit"
        let saved = try store.saveProject(concurrent, expectedRevision: project.revision)
        XCTAssertFalse(model.finish(in: store))
        XCTAssertEqual(store.project(id: project.id), saved)
        let undone = try store.undo(projectID: project.id)
        XCTAssertEqual(undone.clips, project.clips)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_selectedLayers_dragCommitsOneSharedDeltaAndUndoRestoresBoth() throws {
        let (store, original, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = original
        project.subtitles = [TimedSubtitle(startTime: 0.5, endTime: 1, text: "First"),
            TimedSubtitle(startTime: 1.5, endTime: 2, text: "Second")]
        project = try store.saveProject(project, expectedRevision: project.revision)
        let model = TimelineLayerDragModel()
        let selection = Set(project.subtitles.map { ProjectEditReference(target: .subtitle, id: $0.id) })
        model.update(target: .subtitle(project.subtitles[0].id), translation: 100, canvasWidth: 400,
            project: project, selection: selection, playhead: 3, snapEnabled: false)
        XCTAssertTrue(model.includes(.subtitle(project.subtitles[1].id)))
        XCTAssertEqual(store.project(id: project.id), project)
        model.finish(in: store)
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.subtitles.map(\.startTime), [1.5, 2.5])
        XCTAssertEqual(saved.revision, project.revision + 1)
        let undone = try store.undo(projectID: project.id)
        XCTAssertEqual(undone.subtitles, project.subtitles)
    }

    func test_commonPropertySheet_displaysMixedValuesAndChangesOnlyChosenField() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var original = initial
        original.clips[0].placement.anchorX = 0.2
        original.clips[1].placement.anchorX = 0.8
        original = try store.saveProject(original, expectedRevision: original.revision)
        let targets = original.clips.map { ProjectEditReference(target: .clip, id: $0.id) }
        let session = try BatchPropertySession.make(project: original, targets: targets)
        XCTAssertEqual(Set(session.values["anchor_x"] ?? []).count, 2)
        let view = NSHostingView(rootView: BatchPropertySheet(store: store, session: session)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("0.4", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot(view, name: "mixed-common-property")
        let point = NSPoint(x: 350, y: 30)
        send(.leftMouseDown, point, window)
        send(.leftMouseUp, point, window)
        try await Task.sleep(for: .milliseconds(150))
        let saved = try XCTUnwrap(store.project(id: original.id))
        XCTAssertEqual(saved.revision, original.revision + 1)
        XCTAssertEqual(saved.clips.map { $0.placement.anchorX }, [0.4, 0.4])
        XCTAssertEqual(saved.clips.map(\.sourceStart), original.clips.map(\.sourceStart))
        XCTAssertEqual(saved.clips.map(\.sourceEnd), original.clips.map(\.sourceEnd))
        XCTAssertEqual(saved.subtitles, original.subtitles)
        XCTAssertEqual(try store.undo(projectID: original.id).clips, original.clips)
    }

    func test_nativeClipEdgesAndBody_trimAndReorderThroughOneCommitEach() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = store.repository.assetURL(projectID: initial.id, filename: "source.mp4")
        _ = try await TestVideoFactory.makeMovie(at: source, includeAudio: false, duration: 6, width: 320, height: 180)
        let bytes = try Data(contentsOf: source)
        for width in [1100.0, 760.0] {
            let hosted = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: initial.id)
                .frame(width: width, height: 760).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosted
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(500))
            let before = try XCTUnwrap(store.project(id: initial.id))
            let bridge = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineScrollBridgeView }.first)
            let canvas = try XCTUnwrap(bridge.enclosingScrollView?.documentView)
            let scale = canvas.bounds.width / before.timelineDuration
            let point = canvas.convert(NSPoint(x: before.clips[0].outputDuration * scale - 5,
                y: canvas.isFlipped ? 71 : canvas.bounds.height - 71), to: nil)
            let seconds = width == 760 ? 0.48 : 0.5
            let flags: NSEvent.ModifierFlags = width == 760 ? [.option] : []
            let distance = scale * seconds
            send(.leftMouseDown, point, window, flags: flags)
            try await Task.sleep(for: .milliseconds(50))
            send(.leftMouseDragged, NSPoint(x: point.x + distance / 2, y: point.y), window, flags: flags)
            try await Task.sleep(for: .milliseconds(50))
            send(.leftMouseDragged, NSPoint(x: point.x + distance - scale * 0.05, y: point.y), window, flags: flags)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.project(id: initial.id), before)
            try snapshot(hosted, name: "clip-trim-preview-\(Int(width))")
            send(.leftMouseUp, NSPoint(x: point.x + distance, y: point.y), window, flags: flags)
            try await Task.sleep(for: .milliseconds(250))
            let trimmed = try XCTUnwrap(store.project(id: initial.id))
            XCTAssertEqual(trimmed.clips[0].sourceEnd, 3 + seconds, accuracy: 0.01)
            XCTAssertEqual(trimmed.subtitles[0].startTime, 2.5 + seconds, accuracy: 0.01)
            XCTAssertEqual(trimmed.revision, before.revision + 1)
            _ = try store.undo(projectID: initial.id)
            try await Task.sleep(for: .milliseconds(250))
            let restored = try XCTUnwrap(store.project(id: initial.id))
            let currentScale = canvas.bounds.width / restored.timelineDuration
            let center = canvas.convert(NSPoint(x: restored.clips[0].outputDuration * currentScale / 2,
                y: canvas.isFlipped ? 71 : canvas.bounds.height - 71), to: nil)
            let movement = restored.clips[0].outputDuration * currentScale * 1.2
            send(.leftMouseDown, center, window)
            try await Task.sleep(for: .milliseconds(50))
            send(.leftMouseDragged, NSPoint(x: center.x + movement, y: center.y), window)
            try await Task.sleep(for: .milliseconds(50))
            send(.leftMouseUp, NSPoint(x: center.x + movement, y: center.y), window)
            try await Task.sleep(for: .milliseconds(200))
            let moved = try XCTUnwrap(store.project(id: initial.id))
            XCTAssertEqual(moved.clips.map(\.id), restored.clips.reversed().map(\.id))
            XCTAssertEqual(moved.revision, restored.revision + 1)
            _ = try store.undo(projectID: initial.id)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            try await Task.sleep(for: .milliseconds(200))
            let beforeDelete = try XCTUnwrap(store.project(id: initial.id))
            let pixelsPerSecond = canvas.bounds.width / beforeDelete.timelineDuration
            for (time, flags) in [(1.0, NSEvent.ModifierFlags()), (3.0, NSEvent.ModifierFlags.command)] {
                let point = canvas.convert(NSPoint(x: time * pixelsPerSecond,
                    y: canvas.isFlipped ? 71 : canvas.bounds.height - 71), to: nil)
                send(.leftMouseDown, point, window, flags: flags)
                send(.leftMouseUp, point, window, flags: flags)
                try await Task.sleep(for: .milliseconds(100))
            }
            try snapshot(hosted, name: "clip-multiple-selection-\(Int(width))")
            let bars = descendants(hosted).compactMap { $0 as? NSScrollView }.compactMap(\.documentView)
                .filter { $0.bounds.height >= 16 && $0.bounds.height < 40 && $0.bounds.width > 300 }
            let selectionBar = try XCTUnwrap(bars.min {
                $0.convert(NSPoint(x: 0, y: $0.bounds.midY), to: nil).y
                    < $1.convert(NSPoint(x: 0, y: $1.bounds.midY), to: nil).y
            })
            let centerDelete = selectionBar.convert(NSPoint(x: 183, y: selectionBar.bounds.midY), to: nil)
            click(centerDelete, window)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(store.project(id: initial.id)?.clips.count, 0)
            XCTAssertEqual(store.project(id: initial.id)?.revision, beforeDelete.revision + 1)
            XCTAssertEqual(try store.undo(projectID: initial.id).clips, beforeDelete.clips)
        }
    }

    private func fixture() throws -> (AppStore, DemoProject, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clip-interaction-\(UUID())")
        let repository = ProjectRepository(rootURL: root)
        var project = DemoProject(name: "Synthetic clip edits", recording: VideoRecordingAsset(
            filename: "source.mp4", duration: 6, width: 320, height: 180))
        project.clips = [VideoClip(sourceStart: 1, sourceEnd: 3), VideoClip(sourceStart: 4, sourceEnd: 6)]
        project.subtitles = [TimedSubtitle(startTime: 2.5, endTime: 3.5, text: "Linked scene",
            sceneAnchor: try SceneTiming.anchor(at: 2.5, in: project))]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: project.id)), root)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    /// Dispatch only to the owned window; never drain the application's input queue.
    private func click(_ point: NSPoint, _ window: NSWindow) {
        send(.leftMouseDown, point, window)
        send(.leftMouseUp, point, window)
    }
    private func send(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow, flags: NSEvent.ModifierFlags = []) {
        mouseEventNumber += 1
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: mouseEventNumber, clickCount: 1, pressure: 1)!)
    }
    private func snapshot(_ view: NSView, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/timeline-clip-interaction")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }
}
