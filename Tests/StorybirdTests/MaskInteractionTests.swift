import AppKit
import CoreImage
import CoreMedia
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class MaskInteractionTests: XCTestCase {
    func test_nativeMaskCreation_requiresChoicesAndRetainsInvalidDraftThenSavesOnce() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var created: UUID?
        let (window, view) = host(MaskEditingSheet(store: store, session: MaskEditorSession(projectID: project.id, revision: project.revision), onSaved: { created = $0 }), size: CGSize(width: 500, height: 510))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        click(window, at: CGPoint(x: 426, y: 35))
        XCTAssertEqual(store.project(id: project.id), project)
        let menus = descendants(view).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(menus.count, 2)
        for (menu, index) in zip(menus, [1, 2]) {
            menu.selectItem(at: index)
            try XCTUnwrap(menu.menu).performActionForItem(at: index)
        }
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 6)
        try set(fields[2], to: "-0.1", in: window)
        click(window, at: CGPoint(x: 426, y: 35))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertEqual(fields[2].stringValue, "-0.1")
        try set(fields[2], to: "0.2", in: window)
        click(window, at: CGPoint(x: 426, y: 35))
        try await Task.sleep(for: .milliseconds(120))
        let saved = try XCTUnwrap(store.project(id: project.id))
        let id = try XCTUnwrap(created)
        guard case let .mask(value) = saved.effects.first(where: { $0.id == id }) else { return XCTFail("Missing mask") }
        XCTAssertEqual(value.timingMode, .project)
        XCTAssertEqual(value.coordinateSpace, .canvas)
        XCTAssertEqual(value.x, 0.2)
        XCTAssertEqual(value.colorHex, "#000000")
        XCTAssertEqual(saved.revision, project.revision + 1)
        XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_nativeMaskEditing_changesExactBoundsAndOrderAndRetainsStaleInput() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try MaskEditor.create(in: initial, startTime: 0, endTime: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3,
            timingMode: .project, coordinateSpace: .canvas, colorHex: "#FF0000")
        project = try MaskEditor.create(in: project, startTime: 0, endTime: 4, x: 0.2, y: 0.2, width: 0.3, height: 0.3,
            timingMode: .project, coordinateSpace: .canvas, colorHex: "#0000FF")
        project = try store.saveProject(project, expectedRevision: project.revision)
        guard case let .mask(red) = project.effects[0] else { return XCTFail("Missing red mask") }
        let (window, view) = host(MaskEditingSheet(store: store, session: MaskEditorSession(projectID: project.id, revision: project.revision, mask: red)), size: CGSize(width: 500, height: 510))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 7)
        try set(fields[2], to: "0.3", in: window)
        try set(fields[6], to: "1", in: window)
        click(window, at: CGPoint(x: 422, y: 35))
        try await Task.sleep(for: .milliseconds(100))
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.effects.last?.id, red.id)
        guard case let .mask(value) = saved.effects.last else { return XCTFail("Missing updated mask") }
        XCTAssertEqual(value.x, 0.3); XCTAssertEqual(value.colorHex, red.colorHex)
        XCTAssertEqual(saved.revision, project.revision + 1)
        try set(fields[2], to: "0.4", in: window)
        click(window, at: CGPoint(x: 422, y: 35))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id), saved)
        XCTAssertEqual(fields[2].stringValue, "0.4")
        XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
    }

    func test_nativeMaskDrag_distinguishesCanvasFromContentCameraAndCommitsOnlyAtRelease() async throws {
        for space in MaskEffect.CoordinateSpace.allCases {
            let (store, initial, root) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var project = initial
            project.effects = [.panZoom(PanZoomEffect(startTime: 0, endTime: 4, startScale: 2, endX: 0.5, endY: 0.5, endScale: 2))]
            project = try MaskEditor.create(in: project, startTime: 0, endTime: 4, x: 0.2, y: 0.2, width: 0.2, height: 0.2,
                timingMode: .project, coordinateSpace: space)
            project = try store.saveProject(project, expectedRevision: project.revision)
            let effect = project.effects[1], model = PreviewEffectEditModel()
            let (window, view) = host(PreviewEffectControls(store: store, model: model, project: project, effect: effect, time: 1,
                imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300), onBegin: {}).frame(width: 400, height: 300), size: CGSize(width: 400, height: 300))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(180))
            let normalized = space == .canvas ? CGPoint(x: 0.3, y: 0.3) : CGPoint(x: 0.1, y: 0.1)
            let point = view.convert(CGPoint(x: normalized.x * 400, y: view.isFlipped ? normalized.y * 300 : (1 - normalized.y) * 300), to: nil)
            send(.leftMouseDown, point, window)
            send(.leftMouseDragged, CGPoint(x: point.x + 20, y: point.y - 15), window)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(store.project(id: project.id), project)
            send(.leftMouseUp, CGPoint(x: point.x + 40, y: point.y - 30), window)
            try await Task.sleep(for: .milliseconds(100))
            let saved = try XCTUnwrap(store.project(id: project.id))
            guard case let .mask(value) = saved.effects[1] else { return XCTFail("Missing mask") }
            XCTAssertEqual(value.x, space == .canvas ? 0.3 : 0.25, accuracy: 0.005)
            XCTAssertEqual(value.y, space == .canvas ? 0.3 : 0.25, accuracy: 0.005)
            XCTAssertEqual(saved.revision, project.revision + 1)
            XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
        }
    }

    func test_nativeMaskCorner_resizesWithoutMovingOriginAndUndoRestores() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try MaskEditor.create(in: initial, startTime: 0, endTime: 4, x: 0.2, y: 0.2, width: 0.2, height: 0.2,
            timingMode: .project, coordinateSpace: .canvas)
        project = try store.saveProject(project, expectedRevision: project.revision)
        let model = PreviewEffectEditModel()
        let (window, view) = host(PreviewEffectControls(store: store, model: model, project: project, effect: project.effects[0], time: 1,
            imageFrame: CGRect(x: 0, y: 0, width: 400, height: 300), onBegin: {}).frame(width: 400, height: 300), size: CGSize(width: 400, height: 300))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let point = view.convert(CGPoint(x: 160, y: view.isFlipped ? 120 : 180), to: nil)
        send(.leftMouseDown, point, window)
        send(.leftMouseDragged, CGPoint(x: point.x + 20, y: point.y - 15), window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.project(id: project.id), project)
        send(.leftMouseUp, CGPoint(x: point.x + 40, y: point.y - 30), window)
        try await Task.sleep(for: .milliseconds(100))
        let saved = try XCTUnwrap(store.project(id: project.id))
        guard case let .mask(value) = saved.effects[0] else { return XCTFail("Missing mask") }
        XCTAssertEqual(value.x, 0.2); XCTAssertEqual(value.y, 0.2)
        XCTAssertEqual(value.width, 0.3, accuracy: 0.005); XCTAssertEqual(value.height, 0.3, accuracy: 0.005)
        XCTAssertEqual(saved.revision, project.revision + 1)
        XCTAssertEqual(try store.undo(projectID: project.id).effects, project.effects)
    }

    func test_nativeMaskAndFailedComposition_neverExposeUnderlyingPixels() throws {
        var project = DemoProject(name: "Coverage", recording: VideoRecordingAsset(filename: "source.mp4", duration: 2, width: 400, height: 300))
        project = try MaskEditor.create(in: project, startTime: 0, endTime: 2, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
            timingMode: .project, coordinateSpace: .canvas)
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        func raster(_ value: DemoProject) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: ZStack {
                Color.white
                Text("UNDER").font(.system(size: 60, weight: .bold)).foregroundStyle(.red)
                VideoMaskCanvas(project: value, time: 1, imageFrame: frame)
            }.frame(width: 400, height: 300))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        }
        let valid = try raster(project)
        XCTAssertThrowsError(try FrameOverlayRenderer.compositeFrameOverlays(project: project,
            over: CIImage(color: .white).cropped(to: frame), at: .invalid, frame: frame),
            "An unknown render time cannot return unmasked pixels when masks are required.")
        for y in 80..<220 { for x in 105..<295 {
            let pixel = try XCTUnwrap(valid.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent), 0.01)
        } }
        if case var .mask(value) = project.effects[0] { value.colorHex = "invalid"; project.effects[0] = .mask(value) }
        let failed = try raster(project)
        for point in [(10, 10), (390, 290)] {
            let pixel = try XCTUnwrap(failed.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent), 0.01)
        }
        XCTAssertThrowsError(try FrameOverlayRenderer.compositeFrameOverlays(project: project,
            over: CIImage(color: .white).cropped(to: frame), at: CMTime(seconds: 1, preferredTimescale: 600), frame: frame))
    }

    private func fixture() throws -> (AppStore, DemoProject, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mask-native-\(UUID())")
        let repository = ProjectRepository(rootURL: root)
        let project = DemoProject(name: "Native masks", recording: VideoRecordingAsset(filename: "source.mp4", duration: 4, width: 400, height: 300))
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: project.id)), root)
    }
    private func host<V: View>(_ content: V, size: CGSize) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return (window, view)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func set(_ field: NSTextField, to text: String, in window: NSWindow) throws {
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
    }
    private func click(_ window: NSWindow, at point: CGPoint) { send(.leftMouseDown, point, window); send(.leftMouseUp, point, window) }
    private func send(_ type: NSEvent.EventType, _ point: CGPoint, _ window: NSWindow) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
    }
}
