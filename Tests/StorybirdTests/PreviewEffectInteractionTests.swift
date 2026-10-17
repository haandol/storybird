import AppKit
import Foundation
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class PreviewEffectInteractionTests: XCTestCase {
    func test_effectPreview_cancelStaleAndScalePreserveAtomicEditing() throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PreviewEffectEditModel()
        model.begin(project: project, effectID: project.effects[0].id, operation: .moveRectangle,
            time: 1, imageSize: CGSize(width: 400, height: 300))
        model.update(translation: CGSize(width: 40, height: 30))
        XCTAssertEqual(store.project(id: project.id), project)
        if case let .spotlight(value) = model.draft { XCTAssertEqual(value.x, 0.3, accuracy: 0.000001) }
        else { XCTFail("Expected a local spotlight draft") }
        model.cancel()
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        model.begin(project: project, effectID: project.effects[0].id, operation: .bottomRight,
            time: 1, imageSize: CGSize(width: 400, height: 300))
        model.update(translation: CGSize(width: 40, height: 30))
        var concurrent = project
        concurrent.name = "Concurrent"
        let saved = try store.saveProject(concurrent, expectedRevision: project.revision)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), saved)
        _ = try store.undo(projectID: project.id)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_nativeSpotlightCenter_dragCommitsFinalPositionAndUndoOnce() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PreviewEffectEditModel()
        let view = NSHostingView(rootView: PreviewEffectControls(store: store, model: model,
            project: project, effect: project.effects[0], time: 1, imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300), onBegin: {})
            .onExitCommand { model.cancel() }
            .frame(width: 400, height: 300).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let center = view.convert(NSPoint(x: 120, y: view.isFlipped ? 90 : 210), to: nil)
        send(.leftMouseDown, at: center, in: window)
        send(.leftMouseDragged, at: NSPoint(x: center.x + 20, y: center.y - 15), in: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.project(id: project.id), project)
        send(.leftMouseUp, at: NSPoint(x: center.x + 40, y: center.y - 30), in: window)
        try await Task.sleep(for: .milliseconds(100))
        let saved = try XCTUnwrap(store.project(id: project.id))
        guard case let .spotlight(value) = saved.effects[0] else { return XCTFail("Missing spotlight") }
        XCTAssertEqual(value.x, 0.3, accuracy: 0.005)
        XCTAssertEqual(value.y, 0.3, accuracy: 0.005)
        XCTAssertEqual(saved.revision, project.revision + 1)
        XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_nativeSpotlightCorners_eachResizeKeepsOppositeCornerAndOneUndo() async throws {
        for (start, expected) in [
            (CGPoint(x: 80, y: 60), [0.25, 0.25, 0.15, 0.15]),
            (CGPoint(x: 160, y: 60), [0.2, 0.25, 0.25, 0.15]),
            (CGPoint(x: 80, y: 120), [0.25, 0.2, 0.15, 0.25]),
            (CGPoint(x: 160, y: 120), [0.2, 0.2, 0.25, 0.25])
        ] {
            let (store, project, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let model = PreviewEffectEditModel()
            let (window, view) = host(store: store, model: model, project: project)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(160))
            let point = view.convert(NSPoint(x: start.x, y: view.isFlipped ? start.y : 300 - start.y), to: nil)
            send(.leftMouseDown, at: point, in: window)
            send(.leftMouseDragged, at: NSPoint(x: point.x + 10, y: point.y - 8), in: window)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(store.project(id: project.id), project)
            send(.leftMouseUp, at: NSPoint(x: point.x + 20, y: point.y - 15), in: window)
            try await Task.sleep(for: .milliseconds(70))
            let saved = try XCTUnwrap(store.project(id: project.id))
            guard case let .spotlight(value) = saved.effects[0] else { return XCTFail("Missing spotlight") }
            for (actual, wanted) in zip([value.x, value.y, value.width, value.height], expected) { XCTAssertEqual(actual, wanted, accuracy: 0.005) }
            XCTAssertEqual(saved.revision, project.revision + 1)
            XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
            XCTAssertThrowsError(try store.undo(projectID: project.id))
        }
    }

    func test_nativePanCentersAndKeyboardScale_useFinalSharedEdit() async throws {
        for operation in ["start", "end", "startScale", "endScale"] {
            let (store, initial, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var project = initial
            project.effects = [.panZoom(PanZoomEffect(startTime: 0, endTime: 2, startX: 0.2, startY: 0.3,
                startScale: 1, endX: 0.8, endY: 0.3, endScale: 1))]
            project = try store.saveProject(project, expectedRevision: project.revision)
            let model = PreviewEffectEditModel()
            let (window, view) = host(store: store, model: model, project: project)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(160))
            if operation.hasSuffix("Scale") {
                let sliders = descendants(view).compactMap { $0 as? NSSlider }
                XCTAssertEqual(sliders.count, 2)
                let slider = try XCTUnwrap(sliders.dropFirst(operation == "endScale" ? 1 : 0).first)
                window.makeFirstResponder(slider)
                window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                    isARepeat: false, keyCode: 124)))
            } else {
                let point = view.convert(NSPoint(x: operation == "start" ? 80 : 320, y: 150), to: nil)
                send(.leftMouseDown, at: point, in: window)
                send(.leftMouseDragged, at: NSPoint(x: point.x + 20, y: point.y - 15), in: window)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(store.project(id: project.id), project)
                send(.leftMouseUp, at: NSPoint(x: point.x + 40, y: point.y - 30), in: window)
            }
            try await Task.sleep(for: .milliseconds(100))
            let saved = try XCTUnwrap(store.project(id: project.id))
            guard case let .panZoom(value) = saved.effects[0] else { return XCTFail("Missing pan zoom") }
            switch operation {
            case "start": XCTAssertEqual(value.startX, 0.3, accuracy: 0.005); XCTAssertEqual(value.startY, 0.4, accuracy: 0.005)
            case "end": XCTAssertEqual(value.endX, 0.9, accuracy: 0.005); XCTAssertEqual(value.endY, 0.4, accuracy: 0.005)
            case "startScale": XCTAssertGreaterThan(value.startScale, 1); XCTAssertEqual(value.endScale, 1)
            default: XCTAssertGreaterThan(value.endScale, 1); XCTAssertEqual(value.startScale, 1)
            }
            XCTAssertEqual(saved.revision, project.revision + 1)
            XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
        }
    }

    func test_nativeGestureEscape_ignoresFurtherMovementUntilReleaseThenAllowsNextDrag() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PreviewEffectEditModel()
        let (window, view) = host(store: store, model: model, project: project)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(160))
        let point = view.convert(NSPoint(x: 120, y: view.isFlipped ? 90 : 210), to: nil)
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseDragged, at: NSPoint(x: point.x + 20, y: point.y - 15), in: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotNil(model.draft)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(model.draft)
        send(.leftMouseDragged, at: NSPoint(x: point.x + 30, y: point.y - 20), in: window)
        send(.leftMouseUp, at: NSPoint(x: point.x + 40, y: point.y - 30), in: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        send(.leftMouseDown, at: point, in: window)
        send(.leftMouseDragged, at: NSPoint(x: point.x + 20, y: point.y - 15), in: window)
        send(.leftMouseUp, at: NSPoint(x: point.x + 40, y: point.y - 30), in: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
    }

    func test_scaleAdjustment_multipleDraftValuesCommitOnceAndCancelPreservesHistory() throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = initial
        project.effects = [.panZoom(PanZoomEffect(startTime: 0, endTime: 2, endX: 0.5, endY: 0.5, endScale: 1))]
        project = try store.saveProject(project, expectedRevision: project.revision)
        let model = PreviewEffectEditModel()
        model.begin(project: project, effectID: project.effects[0].id, operation: .startScale,
            time: 1, imageSize: CGSize(width: 400, height: 300))
        for scale in [1.1, 1.5, 2] { model.setScale(scale); XCTAssertEqual(store.project(id: project.id), project) }
        model.finish(in: store)
        let saved = try XCTUnwrap(store.project(id: project.id))
        guard case let .panZoom(value) = saved.effects[0] else { return XCTFail("Missing pan zoom") }
        XCTAssertEqual(value.startScale, 2)
        XCTAssertEqual(value.endScale, 1)
        XCTAssertEqual(saved.revision, project.revision + 1)
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.effects, project.effects)
        model.begin(project: restored, effectID: restored.effects[0].id, operation: .endScale,
            time: 1, imageSize: CGSize(width: 400, height: 300))
        model.setScale(2.5); model.cancel(); model.setScale(3); model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), restored)
        XCTAssertEqual(try store.redo(projectID: project.id).effects, saved.effects)
    }

    func test_effectGesture_writeFailurePreservesProjectAndHistory() throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("library-backup.json")
        try FileManager.default.moveItem(at: library, to: backup)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let model = PreviewEffectEditModel()
        model.begin(project: project, effectID: project.effects[0].id, operation: .bottomRight, time: 1, imageSize: CGSize(width: 400, height: 300))
        model.update(translation: CGSize(width: 40, height: 30))
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(model.draft)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: backup, to: library)
        XCTAssertEqual(try store.repository.loadProjects(), [project])
    }

    private func host(store: AppStore, model: PreviewEffectEditModel, project: DemoProject) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: PreviewEffectControls(store: store, model: model, project: project,
            effect: project.effects[0], time: 1, imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300), onBegin: {})
            .onExitCommand { model.cancel() }
            .frame(width: 400, height: 300).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return (window, view)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func fixture() throws -> (AppStore, DemoProject, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effect-edit-\(UUID())")
        let repository = ProjectRepository(rootURL: root)
        var project = DemoProject(name: "Effects", recording: VideoRecordingAsset(filename: "video.mp4", duration: 2, width: 400, height: 300))
        project.effects = [.spotlight(SpotlightEffect(startTime: 0, endTime: 2, x: 0.2, y: 0.2, width: 0.2, height: 0.2))]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: project.id)), root)
    }
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
    }
}
