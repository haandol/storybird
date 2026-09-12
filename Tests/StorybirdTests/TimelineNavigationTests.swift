import AppKit
import AVKit
import StorybirdCore
import SwiftUI
@testable import Storybird
import XCTest

@MainActor
final class TimelineNavigationTests: XCTestCase {
    /// Space is consumed before a focused button, and autorepeat never toggles again.
    func test_spaceInTimeline_togglesOncePerPressWithoutActivatingFocusedButton() throws {
        let window = makeWindow()
        defer { window.close() }
        let scope = TimelinePlaybackKeyView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(scope)
        defer { scope.stopMonitoring() }
        var toggles = 0
        scope.togglePlayback = { toggles += 1 }
        let button = NSButton(title: "Unrelated action", target: nil, action: nil)
        window.contentView?.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        scope.activate(takeFocus: false)
        let space = try key(49, in: window)
        XCTAssertNil(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false))
        XCTAssertEqual(toggles, 1)
        let repeated = try key(49, in: window, repeatKey: true)
        XCTAssertNil(scope.process(repeated, applicationIsActive: true, windowIsKey: true, hasModalWindow: false))
        XCTAssertEqual(toggles, 1)
        XCTAssertNil(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false))
        XCTAssertEqual(toggles, 2)
    }

    /// Text, modified keys, dialogs, inactive windows and Tab keep their existing input path.
    func test_spaceOutsidePlaybackContext_doesNotConsumeInput() throws {
        let window = makeWindow()
        defer { window.close() }
        let scope = TimelinePlaybackKeyView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(scope)
        defer { scope.stopMonitoring() }
        var toggles = 0
        scope.togglePlayback = { toggles += 1 }
        scope.activate(takeFocus: true)
        let space = try key(49, in: window)
        for (active, isKey, modal) in [(false, true, false), (true, false, false), (true, true, true)] {
            XCTAssertTrue(scope.process(space, applicationIsActive: active, windowIsKey: isKey, hasModalWindow: modal) === space)
        }
        for modifier: NSEvent.ModifierFlags in [.command, .option, .shift, .control, .function] {
            let event = try key(49, in: window, modifiers: modifier)
            XCTAssertTrue(scope.process(event, applicationIsActive: true, windowIsKey: true, hasModalWindow: false) === event)
        }
        let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 40))
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertTrue(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false) === space)
        scope.activate(takeFocus: true)
        let tab = try key(48, in: window)
        XCTAssertTrue(scope.process(tab, applicationIsActive: true, windowIsKey: true, hasModalWindow: false) === tab)
        XCTAssertFalse(scope.isInteractionActive)
        XCTAssertTrue(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false) === space)
        XCTAssertEqual(toggles, 0)
    }

    /// A click outside the work area removes ownership even when a canvas is still mounted.
    func test_outsideClick_deactivatesPlaybackKeys() throws {
        let window = makeWindow()
        defer { window.close() }
        let scope = TimelinePlaybackKeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(scope)
        defer { scope.stopMonitoring() }
        scope.activate(takeFocus: true)
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 220, y: 140), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        XCTAssertTrue(scope.process(mouse, applicationIsActive: true, windowIsKey: true, hasModalWindow: false) === mouse)
        XCTAssertFalse(scope.isInteractionActive)
    }

    /// An old hide task cannot erase the next drag's current-time label.
    func test_scrubFeedback_newDragCancelsOldDismissal() async throws {
        let feedback = TimelineScrubFeedback(dismissalDelay: .milliseconds(20))
        feedback.show(1.25, origin: .ruler)
        feedback.finish()
        feedback.show(2.5, origin: .slider)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(feedback.time, 2.5)
        XCTAssertEqual(feedback.origin, .slider)
        feedback.finish()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(feedback.time)
        feedback.show(4, origin: .ruler)
        feedback.cancel()
        XCTAssertNil(feedback.time)
    }

    /// Fit, subsecond ticks and anchored coordinates use the same project-time mapping.
    func test_zoomGeometry_preservesAnchorAndProvidesFractionalTicks() {
        var zoom = TimelineZoom()
        XCTAssertEqual(zoom.canvasWidth(duration: 120, viewportWidth: 600), 5760)
        zoom.set(0, duration: 120, viewportWidth: 600)
        XCTAssertEqual(zoom.canvasWidth(duration: 120, viewportWidth: 600), 600)
        zoom.set(768, duration: 120, viewportWidth: 600)
        let width = zoom.canvasWidth(duration: 120, viewportWidth: 600)
        let step = TimelineZoom.tickInterval(duration: 120, canvasWidth: width)
        XCTAssertEqual(step, 0.1, accuracy: 0.000001)
        XCTAssertEqual(TimelineZoom.label(1.2, interval: step), "0:01.2")
        let offset = TimelineZoom.anchoredOffset(
            time: 30, viewportX: 150, duration: 120, canvasWidth: width, viewportWidth: 600
        )
        XCTAssertEqual(CGFloat(30.0 / 120) * width - offset, 150, accuracy: 0.001)
        let ticks = TimelineZoom.ticks(duration: 120, canvasWidth: width, offset: offset, viewportWidth: 600)
        XCTAssertLessThan(ticks.count, 20)
        XCTAssertTrue(ticks.contains { abs($0 - 30) < 0.000001 })
        XCTAssertEqual(TimelineZoom.anchoredOffset(
            time: 0, viewportX: 150, duration: 120, canvasWidth: width, viewportWidth: 600
        ), 0)
    }

    /// Option-wheel is scoped to the visible clip; ordinary and Shift wheels pass through.
    func test_optionWheel_zoomsAtPointerAndPreservesOtherScrolling() async throws {
        let window = makeWindow()
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 40, y: 20, width: 220, height: 120))
        scroll.hasHorizontalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 100))
        let bridge = TimelineScrollBridgeView(frame: document.bounds)
        document.addSubview(bridge)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let controller = TimelineScrollController()
        bridge.controller = controller
        defer { bridge.stop() }
        var observed: [(Double, CGFloat, Double)] = []
        bridge.zoomAtPointer = { observed.append(($0, $1, $2)) }
        bridge.scheduleUpdate()
        try await Task.sleep(for: .milliseconds(80))
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(80))
        let point = bridge.convert(NSPoint(x: 300, y: 30), to: nil)
        for flags: NSEvent.ModifierFlags in [[], .shift, .control, [.option, .command]] {
            let event = NavigationWheelEvent(window: window, point: point, flags: flags, delta: 1)
            XCTAssertTrue(bridge.processWheel(event, applicationIsActive: true) === event)
        }
        XCTAssertTrue(observed.isEmpty)
        let zoom = NavigationWheelEvent(window: window, point: point, flags: .option, delta: 1)
        XCTAssertNil(bridge.processWheel(zoom, applicationIsActive: true))
        XCTAssertEqual(observed.count, 1)
        let first = try XCTUnwrap(observed.first)
        XCTAssertEqual(first.0, 0.3, accuracy: 0.001)
        XCTAssertEqual(first.1, 100, accuracy: 0.001)
        XCTAssertGreaterThan(first.2, 1)
        let outside = NavigationWheelEvent(
            window: window, point: NSPoint(x: 20, y: point.y), flags: .option, delta: 1
        )
        XCTAssertTrue(bridge.processWheel(outside, applicationIsActive: true) === outside)
        XCTAssertTrue(bridge.processWheel(zoom, applicationIsActive: false) === zoom)
        XCTAssertEqual(observed.count, 1)
        document.setFrameSize(NSSize(width: 2000, height: 100))
        bridge.setFrameSize(document.frame.size)
        controller.requestOffset(450)
        bridge.scheduleUpdate()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scroll.contentView.bounds.minX, 450, accuracy: 0.5)
    }

    /// Pinches share the wheel anchor but need no modifier and retain no stale gesture state.
    func test_pinch_scopesInputAndHandlesExpansionContractionAndCancellation() async throws {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer { window.close(); otherWindow.close() }
        let scroll = NSScrollView(frame: NSRect(x: 40, y: 20, width: 220, height: 120))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 100))
        let bridge = TimelineScrollBridgeView(frame: document.bounds)
        document.addSubview(bridge)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let controller = TimelineScrollController()
        bridge.controller = controller
        defer { bridge.stop() }
        var observed: [(Double, CGFloat, Double)] = []
        bridge.zoomAtPointer = { observed.append(($0, $1, $2)) }
        bridge.scheduleUpdate()
        try await Task.sleep(for: .milliseconds(80))
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let point = bridge.convert(NSPoint(x: 300, y: 30), to: nil)
        for (change, phase): (CGFloat, NSEvent.Phase) in [
            (0.25, .began), (-0.2, .changed), (0, .ended),
            (0.5, .cancelled), (.nan, .changed), (.infinity, .changed),
            (-1, .changed), (-2, .changed), (0.1, .began),
        ] {
            let event = NavigationMagnifyEvent(window: window, point: point, change: change, phase: phase)
            XCTAssertNil(bridge.processMagnify(event, applicationIsActive: true))
        }
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed.map(\.2), [1.25, 0.8, 1.1])
        for sample in observed {
            XCTAssertEqual(sample.0, 0.3, accuracy: 0.001)
            XCTAssertEqual(sample.1, 100, accuracy: 0.001)
        }
        let outside = NavigationMagnifyEvent(window: window, point: NSPoint(x: 20, y: point.y), change: 0.2)
        XCTAssertTrue(bridge.processMagnify(outside, applicationIsActive: true) === outside)
        let wrongWindow = NavigationMagnifyEvent(window: otherWindow, point: point, change: 0.2)
        XCTAssertTrue(bridge.processMagnify(wrongWindow, applicationIsActive: true) === wrongWindow)
        let inactive = NavigationMagnifyEvent(window: window, point: point, change: 0.2)
        XCTAssertTrue(bridge.processMagnify(inactive, applicationIsActive: false) === inactive)
        bridge.isHidden = true
        XCTAssertTrue(bridge.processMagnify(inactive, applicationIsActive: true) === inactive)
        XCTAssertEqual(observed.count, 3)
    }

    /// Exercises the actual workspace's callbacks, native scroll view and player
    /// while keeping all media and event dispatch inside an owned synthetic window.
    func test_workspacePlaybackAndZoom_preserveProjectTimeAndPointerAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let source = try repository.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: source.url, includeAudio: false, duration: 4)
        let project = DemoProject(id: id, name: "Timeline navigation",
            recording: VideoRecordingAsset(filename: source.filename, duration: media.duration,
                                           width: media.width, height: media.height))
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let stored = try XCTUnwrap(store.project(id: id))
        let library = root.appendingPathComponent("library.json")
        let originalLibrary = try Data(contentsOf: library)
        let hosted = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: id)
            .frame(width: 760, height: 760).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 760, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil { self.descendants(hosted).compactMap { $0 as? NSSlider }.count == 2 }
        let sliders = descendants(hosted).compactMap { $0 as? NSSlider }
        let playhead = try XCTUnwrap(sliders.first)
        let zoomSlider = try XCTUnwrap(sliders.last)
        let controls = playhead.convert(playhead.bounds, to: nil)
        let point = NSPoint(x: 380, y: (controls.midY + 29 + 660) / 2)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )))
        }
        try await waitUntil { self.descendants(hosted).contains { $0 is AVPlayerView } }
        let surface = try XCTUnwrap(descendants(hosted).compactMap { $0 as? AVPlayerView }.first)
        let player = try XCTUnwrap(surface.player)
        try await waitUntil { player.currentItem?.status == .readyToPlay }
        let scope = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelinePlaybackKeyView }.first)
        scope.activate(takeFocus: true)
        let space = try key(49, in: window)
        XCTAssertNil(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false))
        try await waitUntil { player.rate > 0 }
        XCTAssertNil(scope.process(space, applicationIsActive: true, windowIsKey: true, hasModalWindow: false))
        XCTAssertEqual(player.rate, 0)
        playhead.doubleValue = playhead.minValue + 0.5 * (playhead.maxValue - playhead.minValue)
        XCTAssertTrue(playhead.sendAction(playhead.action, to: playhead.target))
        try await waitUntil { abs(player.currentTime().seconds - 2) < 0.02 }
        let time = player.currentTime().seconds
        let bridge = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineScrollBridgeView }.first)
        let controller = try XCTUnwrap(bridge.controller)
        let oldWidth = bridge.bounds.width
        zoomSlider.doubleValue = zoomSlider.maxValue
        XCTAssertTrue(zoomSlider.sendAction(zoomSlider.action, to: zoomSlider.target))
        try await waitUntil { bridge.bounds.width > oldWidth * 2 && controller.pendingOffset == nil }
        XCTAssertEqual(player.currentTime().seconds, time, accuracy: 0.001)
        zoomSlider.doubleValue = zoomSlider.minValue
        XCTAssertTrue(zoomSlider.sendAction(zoomSlider.action, to: zoomSlider.target))
        try await waitUntil { abs(bridge.bounds.width - controller.viewportWidth) < 2 && controller.pendingOffset == nil }
        XCTAssertEqual(controller.offset, 0, accuracy: 0.5)
        let pointer = NSPoint(x: controller.offset + controller.viewportWidth / 2, y: bridge.visibleRect.midY)
        let inWindow = bridge.convert(pointer, to: nil)
        let underPointer = Double(pointer.x / bridge.bounds.width) * 4
        let event = NavigationWheelEvent(window: window, point: inWindow, flags: .option, delta: 4)
        XCTAssertNil(bridge.processWheel(event, applicationIsActive: true))
        XCTAssertNil(bridge.processWheel(event, applicationIsActive: true))
        try await waitUntil { bridge.bounds.width > controller.viewportWidth + 20 && controller.pendingOffset == nil }
        let after = bridge.convert(inWindow, from: nil)
        XCTAssertEqual(Double(after.x / bridge.bounds.width) * 4, underPointer, accuracy: 0.02)
        XCTAssertEqual(player.currentTime().seconds, time, accuracy: 0.001)
        let beforePinchWidth = bridge.bounds.width
        for phase: NSEvent.Phase in [.began, .changed] {
            let pinch = NavigationMagnifyEvent(window: window, point: inWindow, change: 0.2, phase: phase)
            XCTAssertNil(bridge.processMagnify(pinch, applicationIsActive: true))
        }
        try await waitUntil { bridge.bounds.width > beforePinchWidth * 1.3 && controller.pendingOffset == nil }
        let pinched = bridge.convert(inWindow, from: nil)
        XCTAssertEqual(Double(pinched.x / bridge.bounds.width) * 4, underPointer, accuracy: 0.02)
        let expandedWidth = bridge.bounds.width
        let contraction = NavigationMagnifyEvent(window: window, point: inWindow, change: -0.2)
        XCTAssertNil(bridge.processMagnify(contraction, applicationIsActive: true))
        try await waitUntil { bridge.bounds.width < expandedWidth * 0.9 && controller.pendingOffset == nil }
        XCTAssertEqual(Double(bridge.convert(inWindow, from: nil).x / bridge.bounds.width) * 4, underPointer, accuracy: 0.02)
        XCTAssertEqual(player.currentTime().seconds, time, accuracy: 0.001)
        XCTAssertEqual(bridge.enclosingScrollView?.magnification, 1)
        let ruler = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineRulerInputView }.first)
        let rulerFrame = ruler.convert(ruler.bounds, to: nil)
        for (type, fraction): (NSEvent.EventType, CGFloat) in [
            (.leftMouseDown, 0.55), (.leftMouseDragged, 0.6), (.leftMouseUp, 0.6),
        ] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: NSPoint(x: rulerFrame.minX + fraction * ruler.bounds.width, y: rulerFrame.midY),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )))
        }
        try await Task.sleep(for: .milliseconds(150))
        print("RULER_NAV time=\(player.currentTime().seconds) frame=\(rulerFrame) bounds=\(ruler.bounds) visible=\(ruler.visibleRect)")
        try await waitUntil { abs(player.currentTime().seconds - 2.4) < 0.02 }
        XCTAssertEqual(store.project(id: id), stored)
        XCTAssertEqual(try Data(contentsOf: library), originalLibrary)
        XCTAssertThrowsError(try store.undo(projectID: id))
    }

    /// Finds controls only inside the synthetic workspace.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Yields for native view/player readiness without activating a user window.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(4) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Owned workspace did not reach the expected state.")
        if !condition() { throw NSError(domain: "TimelineNavigationTests", code: 1) }
    }

    /// Native windows remain isolated; tests never activate an app or move the system pointer.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        return window
    }

    /// Constructs a key addressed only to the synthetic test window.
    private func key(
        _ code: UInt16, in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: code == 48 ? "\t" : " ", charactersIgnoringModifiers: code == 48 ? "\t" : " ",
            isARepeat: repeatKey, keyCode: code
        ))
    }
}

/// Immutable event metadata tests the same local wheel handler without posting input.
private final class NavigationWheelEvent: NSEvent, @unchecked Sendable {
    let targetWindow: NSWindow
    let point: NSPoint
    let flags: NSEvent.ModifierFlags
    let delta: CGFloat

    /// Only supplied immutable metadata is exposed by this synthetic event.
    init(window: NSWindow, point: NSPoint, flags: NSEvent.ModifierFlags, delta: CGFloat) {
        targetWindow = window
        self.point = point
        self.flags = flags
        self.delta = delta
        super.init()
    }

    /// Tests construct these events directly, never from an archive.
    required init?(coder: NSCoder) { nil }

    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var momentumPhase: NSEvent.Phase { [] }
}

/// Immutable magnify metadata exercises production handling without synthesizing user touches.
private final class NavigationMagnifyEvent: NSEvent, @unchecked Sendable {
    let targetWindow: NSWindow
    let point: NSPoint
    let change: CGFloat
    let gesturePhase: NSEvent.Phase

    /// A native magnification value is incremental, unlike a recognizer's accumulated scale.
    init(window: NSWindow, point: NSPoint, change: CGFloat, phase: NSEvent.Phase = .changed) {
        targetWindow = window
        self.point = point
        self.change = change
        gesturePhase = phase
        super.init()
    }

    /// Synthetic tests create events directly rather than decoding archives.
    required init?(coder: NSCoder) { nil }

    override var type: NSEvent.EventType { .magnify }
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { change }
    override var phase: NSEvent.Phase { gesturePhase }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
