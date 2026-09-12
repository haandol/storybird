import AppKit
import AVKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class TimelinePreviewLayoutTests: XCTestCase {
    /// Timing controls and the layer form must stay in the same right-hand pane.
    func test_selectedSubtitleAndAudio_keepExactlyTwoEditorColumns() async throws {
        let (store, initial) = try await fixture()
        var project = initial
        project.subtitles = Array(project.subtitles.prefix(1))
        project = try store.saveProject(project, expectedRevision: initial.revision)
        let sound = store.repository.rootURL.appendingPathComponent("inspector-source.wav")
        try TestVideoFactory.makeToneWAV(at: sound, duration: 1)
        let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: sound)
        project = try store.placeAudioAsset(
            projectID: project.id, assetID: asset.id, expectedRevision: project.revision, startTime: 0.5
        )
        let before = try XCTUnwrap(store.project(id: project.id))
        let library = store.repository.rootURL.appendingPathComponent("library.json")
        let bytes = try Data(contentsOf: library)
        let view = NSHostingView(rootView: editorContent(store, project: project, width: 1100, height: 760))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1100, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        await settle()
        let split = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSplitView }.first)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        for kind: TimelineTrack.Kind in [.subtitle, .narration] {
            let bridge = try XCTUnwrap(descendants(view).compactMap { $0 as? TimelineScrollBridgeView }.first)
            let row = try XCTUnwrap(TimelineTrackLayout.rows(in: project).firstIndex { $0.kind == kind })
            let frame = bridge.convert(bridge.bounds, to: nil)
            let point = NSPoint(
                x: frame.minX + bridge.bounds.width / CGFloat(project.timelineDuration),
                y: frame.maxY - (52 + CGFloat(row) * 44 + 19)
            )
            sendMouse(.leftMouseDown, at: point, in: window)
            sendMouse(.leftMouseUp, at: point, in: window)
            await settle()
            XCTAssertEqual(split.arrangedSubviews.count, 2, "\(kind): Timing must not create a third split column.")
            try snapshot(view, name: "inspector-two-columns-\(kind)")
            XCTAssertEqual(store.project(id: project.id), before)
            XCTAssertEqual(try Data(contentsOf: library), bytes)
        }
    }

    func test_previewVisibility_startsEmptyAndRepeatedTogglesRestoreActualPreview() {
        var layout = TimelinePreviewLayout()
        XCTAssertEqual(layout.visibility, .empty)
        layout.toggleVisibility()
        XCTAssertEqual(layout.visibility, .hidden)
        for _ in 0..<5 {
            layout.toggleVisibility()
            XCTAssertEqual(layout.visibility, .visible)
            layout.toggleVisibility()
            XCTAssertEqual(layout.visibility, .hidden)
        }
    }

    func test_boundaryDrag_clampsBothEndsAndPreservesTimelineSpace() {
        var layout = TimelinePreviewLayout()
        for visibility in [TimelinePreviewLayout.Visibility.empty, .visible] {
            layout.visibility = visibility
            layout.resize(from: 250, translation: 80, totalHeight: 760, minimumTimelineHeight: 208)
            XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 330)
            layout.resize(from: 250, translation: 10_000, totalHeight: 760, minimumTimelineHeight: 208)
            XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 542)
            layout.resize(from: 250, translation: -10_000, totalHeight: 760, minimumTimelineHeight: 208)
            XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 100)
        }
    }

    func test_hiddenPreview_reservesNoHeightAndIgnoresDrags() {
        var layout = TimelinePreviewLayout()
        layout.toggleVisibility()
        let hidden = layout
        for height: CGFloat in [0, 300, 520, 760, 1200] {
            XCTAssertEqual(layout.previewHeight(totalHeight: height, minimumTimelineHeight: 208), 0)
            layout.resize(from: 200, translation: 30, totalHeight: height, minimumTimelineHeight: 208)
            XCTAssertEqual(layout, hidden)
        }
    }

    func test_windowShrink_preservesToolsAndDoesNotErasePreferredSplit() {
        let layout = TimelinePreviewLayout(visibility: .visible, previewFraction: 0.8)
        XCTAssertEqual(layout.previewHeight(totalHeight: 300, minimumTimelineHeight: 208), 82)
        XCTAssertEqual(layout.previewHeight(totalHeight: 100, minimumTimelineHeight: 208), 0)
        XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 542)
        XCTAssertEqual(layout.previewFraction, 0.8)
    }

    func test_hideDuringResize_preservesPreferredHeightUntilShownAgain() {
        var layout = TimelinePreviewLayout()
        layout.resize(from: 250, translation: 80, totalHeight: 760, minimumTimelineHeight: 208)
        let fraction = layout.previewFraction
        layout.toggleVisibility()
        layout.resize(from: 330, translation: 10_000, totalHeight: 760, minimumTimelineHeight: 208)
        XCTAssertEqual(layout.previewFraction, fraction)
        layout.toggleVisibility()
        XCTAssertEqual(layout.visibility, .visible)
        XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 330)
        XCTAssertEqual(TimelinePreviewLayout().visibility, .empty, "A new editor does not inherit this view choice.")
    }

    func test_zeroAvailableHeight_doesNotDivideByZeroOrErasePreferredSplit() {
        var layout = TimelinePreviewLayout(visibility: .visible, previewFraction: 0.6)
        for height: CGFloat in [0, TimelinePreviewLayout.dividerHeight] {
            layout.resize(from: 200, translation: -10_000, totalHeight: height, minimumTimelineHeight: 208)
            XCTAssertEqual(layout.previewFraction, 0.6)
            XCTAssertEqual(layout.previewHeight(totalHeight: height, minimumTimelineHeight: 208), 0)
        }
        XCTAssertEqual(layout.previewHeight(totalHeight: 760, minimumTimelineHeight: 208), 450)
    }

    func test_previewUI_emptyLoadToggleAndResizePreserveProjectInWideAndCompactWindows() async throws {
        let (store, project) = try await fixture()
        for width in [1100.0, 760.0] {
            let view = NSHostingView(rootView: editorContent(store, project: project, width: width, height: 760))
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: width, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            view.sizingOptions = []
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            await settle()
            XCTAssertFalse(descendants(view).contains { $0 is AVPlayerView })
            let initialHeight = try timelineViewport(view).frame.height
            try snapshot(view, name: "empty-\(Int(width))")

            // A placeholder can be hidden before any actual frame is displayed.
            try togglePreview(in: view)
            await settle()
            XCTAssertGreaterThan(try timelineViewport(view).frame.height, initialHeight + 100)
            try togglePreview(in: view)
            await settle()
            XCTAssertTrue(descendants(view).contains { $0 is AVPlayerView })

            for delta in [-80.0, 100.0] {
                let before = try timelineViewport(view).frame.height
                let divider = try XCTUnwrap(descendants(view).compactMap { $0 as? TimelinePreviewDividerView }.first)
                let rect = divider.convert(divider.bounds, to: nil)
                let start = NSPoint(x: rect.midX, y: rect.midY)
                sendMouse(.leftMouseDown, at: start, in: window)
                for portion in [0.1, 0.5, 1.0] {
                    sendMouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - delta * portion), in: window)
                    try await Task.sleep(for: .milliseconds(40))
                }
                await settle()
                let during = try timelineViewport(view).frame.height
                XCTAssertEqual(during - before, -delta, accuracy: 3)
                sendMouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - delta), in: window)
                await settle()
                XCTAssertEqual(try timelineViewport(view).frame.height, during, accuracy: 2)
                XCTAssertEqual(store.project(id: project.id), project)
            }
            try snapshot(view, name: "visible-\(Int(width))")
            for _ in 0..<3 {
                try togglePreview(in: view)
                await settle()
                XCTAssertFalse(descendants(view).contains { $0 is AVPlayerView })
                try togglePreview(in: view)
                await settle()
                XCTAssertTrue(descendants(view).contains { $0 is AVPlayerView })
            }
            try togglePreview(in: view)
            await settle()
            let hiddenHeight = try timelineViewport(view).frame.height
            view.rootView = editorContent(store, project: project, width: width, height: 960)
            window.setContentSize(NSSize(width: width, height: 960))
            await settle()
            XCTAssertEqual(try timelineViewport(view).frame.height - hiddenHeight, 200, accuracy: 3)
            view.rootView = editorContent(store, project: project, width: width, height: 520)
            window.setContentSize(NSSize(width: width, height: 520))
            await settle()
            let viewport = try timelineViewport(view)
            XCTAssertGreaterThan(viewport.frame.height, 200)
            let document = try XCTUnwrap(viewport.documentView)
            document.scroll(NSPoint(x: 0, y: document.bounds.height))
            await settle()
            XCTAssertGreaterThan(viewport.contentView.bounds.minY, 0)
            XCTAssertGreaterThan(try playbackFrame(view).minY, 0)
            try snapshot(view, name: "hidden-small-\(Int(width))")
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
        }
    }

    func test_emptyPreview_showButtonLoadsActualPlayer() async throws {
        let (store, project) = try await fixture()
        let view = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: project.id)
            .frame(width: 760, height: 760).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.sizingOptions = []
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        await settle()
        try snapshot(view, name: "single-empty")
        let slider = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSlider }.first)
        let controls = slider.convert(slider.bounds, to: nil)
        let start = NSPoint(x: 380, y: (controls.midY + 29 + 660) / 2)
        sendMouse(.leftMouseDown, at: start, in: window)
        sendMouse(.leftMouseUp, at: start, in: window)
        await settle()
        XCTAssertTrue(descendants(view).contains { $0 is AVPlayerView })
        XCTAssertEqual(store.project(id: project.id), project)
    }

    func test_unreadableVideo_showsUnavailableWorkspaceBeforePreviewIsRequested() async throws {
        let (store, project) = try await fixture()
        let url = store.repository.assetURL(projectID: project.id, filename: project.recording!.filename)
        try Data("unreadable synthetic video".utf8).write(to: url)
        let view = NSHostingView(rootView: editorContent(store, project: project, width: 760, height: 520))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(descendants(view).contains { $0 is AVPlayerView || $0 is NSSlider || $0 is NSScrollView })
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        try snapshot(view, name: "unreadable-video")
    }

    func test_smallWindowResize_keepsControlsAndLayerScrollingWithAudioPanel() async throws {
        let (store, project) = try await fixture()
        for width in [1100.0, 760.0] {
            let view = NSHostingView(rootView: editorContent(store, project: project, width: width, height: 520))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            await settle()
            NotificationCenter.default.post(name: .storybirdOpenProjectAudio, object: project.id)
            await settle()
            for showingVideo in [false, true] {
                if showingVideo {
                    try togglePreview(in: view)
                    await settle()
                    try togglePreview(in: view)
                    await settle()
                }
                for delta in [-10_000.0, 10_000.0] {
                    let divider = try XCTUnwrap(descendants(view).compactMap { $0 as? TimelinePreviewDividerView }.first)
                    let rect = divider.convert(divider.bounds, to: nil)
                    let start = NSPoint(x: rect.midX, y: rect.midY)
                    sendMouse(.leftMouseDown, at: start, in: window)
                    sendMouse(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - delta), in: window)
                    sendMouse(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - delta), in: window)
                    await settle()
                    let viewport = try timelineViewport(view)
                    XCTAssertGreaterThan(viewport.frame.height, 50)
                    let visible = viewport.convert(viewport.bounds, to: view)
                    XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(visible))
                    XCTAssertGreaterThan(try playbackFrame(view).minY, 0)
                    XCTAssertEqual(descendants(view).contains { $0 is AVPlayerView }, showingVideo)
                    XCTAssertEqual(store.project(id: project.id), project)
                }
            }
            try snapshot(view, name: "audio-small-\(Int(width))")
            XCTAssertThrowsError(try store.undo(projectID: project.id))
        }
    }

    /// Creates only synthetic video and overlapping subtitles in a temporary library.
    private func fixture() async throws -> (AppStore, DemoProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let id = UUID()
        let asset = try repository.prepareVideoRecordingURL(projectID: id)
        _ = try await TestVideoFactory.makeMovie(at: asset.url, includeAudio: false, duration: 3)
        var project = DemoProject(id: id, name: "Preview layout",
            recording: VideoRecordingAsset(filename: asset.filename, duration: 3, width: 1280, height: 720))
        project.subtitles = (0..<20).map {
            TimedSubtitle(startTime: 0.2, endTime: 2, text: "Synthetic layer \($0 + 1)")
        }
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: id)))
    }

    /// Uses an explicit proposal so the hosting window matches real app content sizing.
    private func editorContent(_ store: AppStore, project: DemoProject, width: Double, height: Double) -> some View {
        ProjectWorkspaceView(store: store, projectID: project.id)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
    }

    /// Anchors synthetic pointer input to the native playhead control's current layout.
    private func playbackFrame(_ view: NSView) throws -> NSRect {
        let slider = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSlider }.first)
        return slider.convert(slider.bounds, to: nil)
    }

    /// Clicks the preview toggle beside the playhead in the actual hosted editor.
    private func togglePreview(in view: NSView) throws {
        let window = try XCTUnwrap(view.window)
        let controls = try playbackFrame(view)
        let start = NSPoint(x: 80, y: controls.midY)
        sendMouse(.leftMouseDown, at: start, in: window)
        sendMouse(.leftMouseUp, at: start, in: window)
    }

    /// Locates the tall layer scroll document rather than the side inspector.
    private func timelineViewport(_ view: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
            $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > 900
        })
    }

    /// Searches native view descendants without touching other application windows.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Delivers drag events directly to the test window without global pointer input.
    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        window.sendEvent(event)
    }

    /// Allows the hosted SwiftUI tree to process an action and update layout.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(180))
    }

    /// Stores synthetic screenshots under build output for visual review.
    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/timeline-preview-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
