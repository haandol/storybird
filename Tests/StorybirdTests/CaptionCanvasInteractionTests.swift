import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class CaptionCanvasInteractionTests: XCTestCase {
    func test_nativeCaptionEditor_editsWholeTextAndSplitMergePreserveUndo() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = initial
        for mode in [CaptionEditorSession.Mode.edit, .split, .merge] {
            let entry = try XCTUnwrap(CaptionListEntry.entries(in: project).first)
            let session = CaptionEditorSession(projectID: project.id, revision: project.revision, entry: entry,
                mode: mode, relatedIDs: mode == .merge ? Array(project.subtitles.dropFirst().map(\.id)) : [],
                combinedText: mode == .merge ? "Merged 👨‍👩‍👧‍👦 caption" : nil)
            let (window, view) = host(CaptionEditorSheet(store: store, session: session), size: CGSize(width: 500, height: 420))
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(180))
            if mode == .edit {
                let textView = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
                window.makeFirstResponder(textView)
                textView.selectAll(nil)
                textView.insertText("Full 👨‍👩‍👧‍👦 caption", replacementRange: NSRange(location: NSNotFound, length: 0))
                window.makeFirstResponder(nil)
            }
            XCTAssertEqual(store.project(id: project.id), project)
            try press("Apply", in: view)
            try await Task.sleep(for: .milliseconds(120))
            let saved = try XCTUnwrap(store.project(id: project.id))
            XCTAssertEqual(saved.revision, project.revision + 1)
            switch mode {
            case .edit: XCTAssertEqual(saved.subtitles[0].text, "Full 👨‍👩‍👧‍👦 caption")
            case .split:
                XCTAssertEqual(saved.subtitles.count, 2)
                XCTAssertEqual(saved.subtitles.map(\.text).joined(), project.subtitles[0].text)
            case .merge:
                XCTAssertEqual(saved.subtitles.count, 1)
                XCTAssertEqual(saved.subtitles[0].text, "Merged 👨‍👩‍👧‍👦 caption")
            }
            XCTAssertEqual(try store.undo(projectID: project.id).subtitles, project.subtitles)
            project = try store.redo(projectID: project.id)
            window.close()
        }
    }

    func test_nativeCaptionStaleSheet_keepsDraftAndConcurrentProject() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try XCTUnwrap(CaptionListEntry.entries(in: project).first)
        let (window, view) = host(CaptionEditorSheet(store: store, session: CaptionEditorSession(
            projectID: project.id, revision: project.revision, entry: entry, mode: .edit)), size: CGSize(width: 500, height: 420))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let textView = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        window.makeFirstResponder(textView)
        textView.selectAll(nil)
        textView.insertText("Uncommitted draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        var changed = project; changed.name = "Concurrent"
        let saved = try store.saveProject(changed, expectedRevision: project.revision)
        try press("Apply", in: view)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.project(id: project.id), saved)
        XCTAssertEqual(textView.string, "Uncommitted draft")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(try store.undo(projectID: project.id).subtitles, project.subtitles)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_nativeCanvasAndPlacement_commitChosenValuesAndUndo() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (window, view) = host(CanvasEditorSheet(store: store, session: CanvasEditorSession(
            projectID: project.id, revision: project.revision, canvas: project.canvas)), size: CGSize(width: 420, height: 330))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        try press("9:16 · 1080×1920", in: view)
        XCTAssertEqual(store.project(id: project.id), project)
        try press("Apply canvas", in: view)
        try await Task.sleep(for: .milliseconds(120))
        let changed = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(changed.canvasSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(changed.revision, project.revision + 1)
        let (placementWindow, placementView) = host(ClipPlacementSheet(store: store, session: ClipPlacementSession(
            projectID: project.id, revision: changed.revision, clipID: changed.clips[0].id, placement: changed.clips[0].placement)),
            size: CGSize(width: 480, height: 300))
        defer { placementWindow.close() }
        try await Task.sleep(for: .milliseconds(180))
        try press("Fill canvas", in: placementView)
        let fields = descendants(placementView).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 2)
        for (field, value) in zip(fields, ["0.25", "0.75"]) {
            placementWindow.makeFirstResponder(field)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            placementWindow.makeFirstResponder(nil)
        }
        XCTAssertEqual(store.project(id: project.id), changed)
        try press("Apply placement", in: placementView)
        try await Task.sleep(for: .milliseconds(120))
        let placed = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(placed.clips[0].placement.mode, .fill)
        XCTAssertEqual(placed.clips[0].placement.anchorX, 0.25)
        XCTAssertEqual(placed.clips[0].placement.anchorY, 0.75)
        XCTAssertEqual(placed.revision, changed.revision + 1)
        XCTAssertEqual(try store.undo(projectID: project.id).clips, changed.clips)
        XCTAssertEqual(try store.undo(projectID: project.id).canvas, project.canvas)
    }

    func test_nativeSRTPanel_importSelectsFullCaptionsForStyle() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("native.srt")
        let text = "Full imported 👨‍👩‍👧‍👦 caption with words preserved"
        let bytes = Data("1\n00:00:00,500 --> 00:00:01,500\n\(text)\n".utf8)
        try bytes.write(to: source)
        let selection = CaptionPanelSelection()
        var style: CaptionStyleSession?
        let content = CaptionPanelHarness(store: store, projectID: project.id, selection: selection,
            source: source, root: root, onStyle: { style = $0 })
        let (window, view) = host(content.frame(width: 400, height: 550), size: CGSize(width: 400, height: 550))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        try press("Import SRT", in: view)
        for _ in 0..<200 {
            if store.project(id: project.id)?.subtitles.count == 2, selection.targets.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let imported = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(imported.subtitles.last?.text, text)
        XCTAssertEqual(imported.subtitles.first, project.subtitles.first)
        XCTAssertEqual(selection.targets, [ProjectEditReference(target: .subtitle, id: try XCTUnwrap(imported.subtitles.last?.id))])
        try await Task.sleep(for: .milliseconds(100))
        try press("Style", in: view)
        XCTAssertEqual(style?.targets, Array(selection.targets))
        XCTAssertEqual(style?.revision, imported.revision)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try store.undo(projectID: project.id).subtitles, project.subtitles)
    }

    func test_nativeCaptionSaveFailure_retainsDraftForRetry() async throws {
        let (store, project, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try XCTUnwrap(CaptionListEntry.entries(in: project).first)
        let (window, view) = host(CaptionEditorSheet(store: store, session: CaptionEditorSession(
            projectID: project.id, revision: project.revision, entry: entry, mode: .edit)), size: CGSize(width: 500, height: 420))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let textView = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        window.makeFirstResponder(textView); textView.selectAll(nil)
        textView.insertText("Retry this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        let library = root.appendingPathComponent("library.json"), backup = root.appendingPathComponent("library-backup.json")
        try FileManager.default.moveItem(at: library, to: backup)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        try press("Apply", in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertEqual(textView.string, "Retry this draft")
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        try FileManager.default.removeItem(at: library)
        try FileManager.default.moveItem(at: backup, to: library)
        try press("Apply", in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id)?.subtitles[0].text, "Retry this draft")
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
    }

    func test_nativeCaptionStyle_changesOnlyFontAcrossCueAndIndependent() async throws {
        let (store, initial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = initial
        var cue = TimedPointerClick(time: 1, x: 0.3, y: 0.4, caption: "Preserved description")
        cue.cueSubtitle.text = "Cue caption"
        cue.cueSubtitle.style.foregroundHex = "#FF0000"
        cue.cueSubtitle.style.fontSize = 26
        project.clicks = [cue]
        project = try store.saveProject(project, expectedRevision: project.revision)
        let session = CaptionStyleSession(projectID: project.id, revision: project.revision,
            targets: [ProjectEditReference(target: .subtitle, id: project.subtitles[0].id), ProjectEditReference(target: .click, id: cue.id)],
            style: project.subtitles[0].style, mixedFields: ["font_size", "foreground_hex"])
        let (window, view) = host(CaptionBulkStyleSheet(store: store, session: session), size: CGSize(width: 380, height: 420))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("32", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(80))
        try press("Apply style", in: view)
        try await Task.sleep(for: .milliseconds(100))
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.subtitles[0].style.fontSize, 32)
        XCTAssertEqual(saved.clicks[0].cueSubtitle.style.fontSize, 32)
        XCTAssertEqual(saved.subtitles[0].style.foregroundHex, project.subtitles[0].style.foregroundHex)
        XCTAssertEqual(saved.clicks[0].cueSubtitle.style.foregroundHex, "#FF0000")
        XCTAssertEqual(saved.clicks[0].description, cue.description)
        XCTAssertTrue(saved.clicks[0].isComplete)
        XCTAssertEqual(saved.revision, project.revision + 1)
        let restored = try store.undo(projectID: project.id)
        XCTAssertEqual(restored.clicks, project.clicks)
        let colors = CaptionStyleSession(projectID: project.id, revision: restored.revision,
            targets: session.targets, style: restored.subtitles[0].style, mixedFields: ["font_size", "foreground_hex"])
        let (colorWindow, colorView) = host(CaptionBulkStyleSheet(store: store, session: colors), size: CGSize(width: 380, height: 420))
        defer { colorWindow.close() }
        try await Task.sleep(for: .milliseconds(180))
        try press("Text color", in: colorView)
        try await Task.sleep(for: .milliseconds(60))
        try press("Apply style", in: colorView)
        try await Task.sleep(for: .milliseconds(100))
        let colored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(colored.clicks[0].cueSubtitle.style.foregroundHex, restored.subtitles[0].style.foregroundHex)
        XCTAssertEqual(colored.subtitles[0].style.fontSize, 17)
        XCTAssertEqual(colored.clicks[0].cueSubtitle.style.fontSize, 26)
        XCTAssertEqual(colored.clicks[0].description, cue.description)
        XCTAssertEqual(colored.revision, restored.revision + 1)
    }

    private func fixture() throws -> (AppStore, DemoProject, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caption-ui-\(UUID())")
        let repository = ProjectRepository(rootURL: root)
        var project = DemoProject(name: "Captions", recording: VideoRecordingAsset(filename: "video.mp4", duration: 4, width: 1280, height: 720))
        project.subtitles = [TimedSubtitle(startTime: 0, endTime: 4, text: "Initial full caption")]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: project.id)), root)
    }
    private func host<V: View>(_ content: V, size: CGSize) -> (NSWindow, NSView) {
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return (window, view)
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func press(_ label: String, in view: NSView) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/authoring-interaction")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(label.replacingOccurrences(of: "/", with: "-") + ".png"))
        let point: NSPoint
        switch label {
        case "Apply": point = NSPoint(x: view.bounds.width - 53, y: 35)
        case "Apply canvas", "Apply placement", "Apply style": point = NSPoint(x: view.bounds.width - 75, y: 35)
        case "9:16 · 1080×1920": point = NSPoint(x: 64, y: view.bounds.height - 110)
        case "Fill canvas": point = NSPoint(x: 236, y: view.bounds.height - 70)
        case "Import SRT": point = NSPoint(x: 114, y: view.bounds.height - 56)
        case "Text color": point = NSPoint(x: 28, y: view.bounds.height - 90)
        case "Style": point = NSPoint(x: 230, y: view.bounds.height - 82)
        default: throw NSError(domain: "Unknown synthetic control", code: 1)
        }
        let window = try XCTUnwrap(view.window)
        let tracksMouse = label == "Fill canvas" || label == "Text color" || label.hasPrefix("9:16")
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
        }
        if tracksMouse {
            // Native radio/checkbox controls track synchronously. Queue only this
            // window's release, then address its press directly; never drain user input.
            NSApp.postEvent(events[1], atStart: true)
            window.sendEvent(events[0])
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
               pending.windowNumber == window.windowNumber, pending.eventNumber == events[1].eventNumber,
               pending.timestamp == events[1].timestamp {
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            }
            window.sendEvent(events[1])
        } else {
            for event in events { window.sendEvent(event) }
        }
    }
}

@MainActor
private final class CaptionPanelSelection: ObservableObject {
    @Published var targets: Set<ProjectEditReference> = []
}

private struct CaptionPanelHarness: View {
    @ObservedObject var store: AppStore
    let projectID: UUID
    @ObservedObject var selection: CaptionPanelSelection
    let source: URL
    let root: URL
    let onStyle: (CaptionStyleSession) -> Void
    var body: some View {
        TimelineCaptionPanel(store: store, projectID: projectID, selection: $selection.targets, onSeek: { _ in },
            onAdd: {}, onStyle: onStyle, chooseImportURL: { source }, chooseExportDirectory: { root })
    }
}
