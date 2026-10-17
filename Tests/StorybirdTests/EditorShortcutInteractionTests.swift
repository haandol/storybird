import AppKit
import AVKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class EditorShortcutInteractionTests: XCTestCase {
    func test_editorKeys_scopeRecordingTextRepeatAndDisabledActions() throws {
        let window = makeWindow()
        let other = makeWindow()
        defer { window.close(); other.close() }
        let scope = TimelinePlaybackKeyView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(scope)
        defer { scope.stopMonitoring() }
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = StorybirdShortcutSettings(defaults: defaults)
        scope.shortcutSettings = settings
        var edits: [StorybirdCommandAction] = [], frames: [Int] = [], boundaries: [Int] = []
        var deletes = 0, plays = 0
        scope.performEdit = { edits.append($0); return true }
        scope.stepFrame = { frames.append($0) }
        scope.stepBoundary = { boundaries.append($0) }
        scope.deleteSelection = { deletes += 1; return true }
        scope.togglePlayback = { plays += 1 }
        let inputs: [(UInt16, NSEvent.ModifierFlags)] = [(11, .command), (2, .command), (6, .command), (6, [.command, .shift]),
            (51, []), (117, []), (123, .function), (124, []), (125, []), (126, []), (49, [])]
        for (code, flags) in inputs {
            let event = try key(code, flags, window)
            scope.activate(takeFocus: true)
            for (active, isKey, modal) in [(false, true, false), (true, false, false), (true, true, true)] {
                XCTAssertTrue(scope.process(event, applicationIsActive: active, windowIsKey: isKey, hasModalWindow: modal) === event)
            }
            let wrong = try key(code, flags, other)
            XCTAssertTrue(process(wrong, scope) === wrong)
            settings.recordingAction = .splitSelection
            XCTAssertTrue(process(event, scope) === event)
            settings.recordingAction = nil
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
            window.contentView?.addSubview(text)
            XCTAssertTrue(window.makeFirstResponder(text))
            XCTAssertTrue(process(event, scope) === event)
            text.removeFromSuperview()
            scope.activate(takeFocus: true)
            scope.isPlaybackEnabled = false
            XCTAssertTrue(process(event, scope) === event)
            scope.isPlaybackEnabled = true
            scope.isInteractionActive = false
            XCTAssertTrue(process(event, scope) === event)
            scope.activate(takeFocus: true)
            XCTAssertNil(process(event, scope))
            XCTAssertNil(process(try key(code, flags, window, repeated: true), scope))
        }
        XCTAssertEqual(edits, [.splitSelection, .duplicateSelection, .undoEdit, .redoEdit])
        XCTAssertEqual(frames, [-1, -1, 1, 1])
        XCTAssertEqual(boundaries, [1, 1, -1, -1])
        XCTAssertEqual(deletes, 2)
        XCTAssertEqual(plays, 1)
        scope.performEdit = { _ in false }
        XCTAssertNil(process(try key(11, .command, window), scope))
        XCTAssertEqual(edits.count, 4)
        settings.update(.splitSelection, to: StorybirdShortcut(keyCode: 11, modifiers: [.command, .option]))
        let old = try key(11, .command, window)
        XCTAssertTrue(process(old, scope) === old)
    }

    func test_nativeShortcutRecorder_reassignsDisabledEditorDefaultAndPersists() async throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(11, forKey: "newProject.shortcut.keyCode")
        defaults.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: "newProject.shortcut.modifiers")
        let settings = StorybirdShortcutSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled(.splitSelection))
        let hosted = NSHostingView(rootView: StorybirdShortcutField(settings: settings, action: .splitSelection)
            .frame(width: 300, height: 60))
        let window = makeWindow(width: 300, height: 60)
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 150, y: 30),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await wait { settings.recordingAction == .splitSelection }
        try await Task.sleep(for: .milliseconds(100))
        let responder = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(String(describing: type(of: responder)).contains("KeyCaptureView"))
        responder.keyDown(with: try key(11, [.command, .option], window))
        XCTAssertFalse(settings.isRecordingShortcut)
        XCTAssertTrue(settings.isEnabled(.splitSelection))
        XCTAssertNil(settings.validationError(for: .splitSelection))
        XCTAssertEqual(settings.shortcut(for: .newProject), StorybirdCommandAction.splitSelection.defaultShortcut)
        XCTAssertEqual(StorybirdShortcutSettings(defaults: defaults).shortcut(for: .splitSelection),
            StorybirdShortcut(keyCode: 11, modifiers: [.command, .option]))
    }

    func test_frameSteps_useExactFractionalGridAndAdjacentFramesBetweenBoundaries() throws {
        let frame = CMTime(value: 1001, timescale: 60000)
        for index in 1...120 {
            let time = Double(index) * frame.seconds
            let next = try XCTUnwrap(VideoPlaybackModel.frameStepTime(from: time, direction: 1, duration: 10, frameDuration: frame))
            XCTAssertEqual(CMTimeCompare(next, CMTime(value: Int64(index + 1) * 1001, timescale: 60000)), 0)
            let previous = try XCTUnwrap(VideoPlaybackModel.frameStepTime(from: time + frame.seconds / 2, direction: -1, duration: 10, frameDuration: frame))
            XCTAssertEqual(CMTimeCompare(previous, CMTime(value: Int64(index) * 1001, timescale: 60000)), 0)
        }
        XCTAssertEqual(VideoPlaybackModel.frameStepTime(from: 0, direction: -1, duration: 2, frameDuration: frame), .zero)
        let last = try XCTUnwrap(VideoPlaybackModel.frameStepTime(from: 2, direction: -1, duration: 2, frameDuration: frame))
        XCTAssertLessThan(last.seconds, 2)
        XCTAssertGreaterThanOrEqual(last.seconds + frame.seconds, 2)
        XCTAssertNil(VideoPlaybackModel.frameStepTime(from: .nan, direction: 1, duration: 2, frameDuration: frame))
        XCTAssertNil(VideoPlaybackModel.frameStepTime(from: 2, direction: 1, duration: 2, frameDuration: frame))
    }

    /// A mounted editor receives only events addressed to its synthetic window.
    /// Real clip selection and menu callbacks share the key command's AppStore edits.
    func test_workspaceKeysAndVisibleButton_shareEditsUndoAndReadOnlyNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let source = try repository.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: source.url, includeAudio: false, duration: 4)
        var initial = DemoProject(id: id, name: "Editor shortcuts", recording: VideoRecordingAsset(
            filename: source.filename, duration: media.duration, width: media.width, height: media.height))
        initial.clips = [VideoClip(sourceStart: 0, sourceEnd: 2), VideoClip(sourceStart: 2, sourceEnd: 4)]
        try repository.saveProjects([initial])
        let store = AppStore(repository: repository)
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = StorybirdShortcutSettings(defaults: defaults)
        let hosted = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: id)
            .environment(\.storybirdShortcuts, settings).frame(width: 1100, height: 760))
        let window = makeWindow(width: 1100, height: 760)
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        try await wait { self.descendants(hosted).contains { $0 is TimelinePlaybackKeyView } }
        try await Task.sleep(for: .milliseconds(500))
        let scope = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelinePlaybackKeyView }.first)
        let bridge = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineScrollBridgeView }.first)
        let canvas = try XCTUnwrap(bridge.enclosingScrollView?.documentView)
        let point = canvas.convert(NSPoint(x: canvas.bounds.width / 4,
            y: canvas.isFlipped ? 71 : canvas.bounds.height - 71), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(200))
        let slider = try XCTUnwrap(descendants(hosted).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = slider.minValue + 0.25 * (slider.maxValue - slider.minValue)
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        try await Task.sleep(for: .milliseconds(150))
        scope.activate(takeFocus: true)
        XCTAssertNil(process(try key(11, .command, window), scope))
        try await wait { store.project(id: id)?.clips.count == 3 }
        let split = try XCTUnwrap(store.project(id: id))
        XCTAssertEqual(split.revision, initial.revision + 1)
        XCTAssertEqual(split.clips.map(\.outputDuration), [1, 1, 2])
        XCTAssertNil(process(try key(6, .command, window), scope))
        try await wait { store.project(id: id)?.clips.count == 2 }
        XCTAssertEqual(store.project(id: id)?.clips, initial.clips)
        XCTAssertNil(process(try key(6, [.command, .shift], window), scope))
        try await wait { store.project(id: id)?.clips.count == 3 }
        XCTAssertEqual(store.project(id: id)?.clips, split.clips)
        try await Task.sleep(for: .milliseconds(250))
        hosted.layoutSubtreeIfNeeded()
        // The visible toolbar button uses the same undo command as Command+Z.
        let ruler = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineRulerInputView }.first)
        let rulerFrame = ruler.convert(ruler.bounds, to: nil)
        let undoPoint = NSPoint(x: 139, y: rulerFrame.maxY + 54)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: undoPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 1)))
        }
        try await wait { store.project(id: id)?.clips.count == 2 }
        XCTAssertEqual(store.project(id: id)?.clips, initial.clips)
        XCTAssertEqual(store.project(id: id)?.revision, initial.revision + 4)
        // Reselect through the clip surface after undo removes split selection IDs.
        try await Task.sleep(for: .milliseconds(250))
        let refreshedBridge = try XCTUnwrap(descendants(hosted).compactMap { $0 as? TimelineScrollBridgeView }.first)
        let refreshedCanvas = try XCTUnwrap(refreshedBridge.enclosingScrollView?.documentView)
        let reselectPoint = refreshedCanvas.convert(NSPoint(x: refreshedCanvas.bounds.width / 4,
            y: refreshedCanvas.isFlipped ? 71 : refreshedCanvas.bounds.height - 71), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: reselectPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(150))
        scope.activate(takeFocus: true)
        XCTAssertNil(process(try key(2, .command, window), scope))
        try await wait { store.project(id: id)?.clips.count == 3 }
        let duplicated = try XCTUnwrap(store.project(id: id))
        XCTAssertEqual(duplicated.clips.map(\.sourceStart), [0, 0, 2])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(process(try key(51, [], window), scope))
        try await wait { store.project(id: id)?.clips.count == 2 }
        XCTAssertEqual(store.project(id: id)?.clips, initial.clips)
        try await Task.sleep(for: .milliseconds(500))
        let beforeNavigation = try XCTUnwrap(store.project(id: id))
        let disk = try Data(contentsOf: root.appendingPathComponent("library.json"))
        slider.doubleValue = slider.minValue + 0.25 * (slider.maxValue - slider.minValue)
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        try await Task.sleep(for: .milliseconds(250))
        let player = try XCTUnwrap(descendants(hosted).compactMap { $0 as? AVPlayerView }.first?.player)
        try await wait { player.currentItem?.status == .readyToPlay && abs(player.currentTime().seconds - 1) < 0.001 }
        scope.activate(takeFocus: true)
        XCTAssertNil(process(try key(124, [], window), scope))
        try await wait { abs(player.currentTime().seconds - (1 + 1.0 / 30)) < 0.001 }
        XCTAssertNil(process(try key(123, [], window), scope))
        try await wait { abs(player.currentTime().seconds - 1) < 0.001 }
        XCTAssertNil(process(try key(125, [], window), scope))
        try await wait { abs(player.currentTime().seconds - 2) < 0.001 }
        XCTAssertNil(process(try key(126, [], window), scope))
        try await wait { abs(player.currentTime().seconds) < 0.001 }
        XCTAssertEqual(store.project(id: id), beforeNavigation)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), disk)
        XCTAssertEqual(try store.undo(projectID: id).clips, duplicated.clips)
    }

    private func process(_ event: NSEvent, _ scope: TimelinePlaybackKeyView) -> NSEvent? {
        scope.process(event, applicationIsActive: true, windowIsKey: true, hasModalWindow: false)
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ window: NSWindow, repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: repeated, keyCode: code))
    }

    private func makeWindow(width: CGFloat = 320, height: CGFloat = 240) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Synthetic editor did not reach the expected state", file: file, line: line)
        if !condition() { throw NSError(domain: "EditorShortcutInteractionTests", code: 1) }
    }
}
