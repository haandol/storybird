import AppKit
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class TimelineAudioTests: XCTestCase {
    /// Owns synthetic audio in a temporary library, with no microphone or model.
    private func fixture() throws -> (AppStore, DemoProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let id = UUID()
        let video = try repository.prepareVideoRecordingURL(projectID: id)
        try Data("synthetic".utf8).write(to: video.url)
        let asset = ProjectAudioAsset(filename: "audio.wav", name: "Introduction", duration: 8, origin: .imported)
        try TestVideoFactory.makeToneWAV(at: repository.assetURL(projectID: id, filename: asset.filename), duration: 8)
        var project = DemoProject(id: id, name: "Audio editing", recording: VideoRecordingAsset(
            filename: video.filename, duration: 20, width: 1280, height: 720
        ))
        project.audioAssets = [asset]
        project = try AudioLayerEditor.place(assetID: asset.id, in: project, startTime: 2, sourceStart: 1,
            duration: 4, timingMode: .scene)
        project.narrations[0].fadeIn = 1
        project.narrations[0].fadeOut = 1
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: id)))
    }

    func test_audioPlacement_fullDurationAtPlayheadSelectsLayerAndUndoRestores() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let reference = TimelineAudioReference(projectID: project.id, itemID: project.audioAssets[0].id,
            kind: .asset, revision: project.revision, token: UUID())
        await model.place(reference, at: 8, in: store)
        let saved = try XCTUnwrap(store.project(id: project.id))
        let placed = try XCTUnwrap(saved.narrations.first { $0.id == model.selectedLayerID })
        XCTAssertEqual(placed.startTime, 8)
        XCTAssertEqual(placed.duration, 8)
        XCTAssertNotNil(placed.sceneAnchor)
        XCTAssertEqual(saved.revision, project.revision + 1)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations, project.narrations)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_audioDrop_providerRoundTripPlacesAtPointerAndRejectsCancelledOrForeignData() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let provider = model.beginDrag(itemID: project.audioAssets[0].id, kind: .asset, project: project)
        let reference = try XCTUnwrap(model.dragging)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: TimelineAudioReference.contentType.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        await model.receiveDrop(Data("foreign".utf8), reference: reference, at: 9, in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        await model.receiveDrop(data, reference: reference, at: 9, in: store)
        XCTAssertEqual(store.project(id: project.id), project, "A cancelled token must not be replayed.")
        _ = model.beginDrag(itemID: project.audioAssets[0].id, kind: .asset, project: project)
        let next = try XCTUnwrap(model.dragging)
        await model.receiveDrop(try JSONEncoder().encode(next), reference: next, at: 9, in: store)
        XCTAssertEqual(store.project(id: project.id)?.narrations.last?.startTime, 9)
        XCTAssertEqual(store.project(id: project.id)?.narrations.last?.duration, 8)
        XCTAssertNil(model.dragging)
    }

    func test_audioDrop_projectSwitchAndStaleRevisionDoNotPublish() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        _ = model.beginDrag(itemID: project.audioAssets[0].id, kind: .asset, project: project)
        let reference = try XCTUnwrap(model.dragging)
        store.selectedProjectID = nil
        await model.receiveDrop(try JSONEncoder().encode(reference), reference: reference, at: 8, in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        store.selectedProjectID = project.id
        var newer = project
        newer.narrations[0].name = "Concurrent change"
        let saved = try store.saveProject(newer, expectedRevision: project.revision)
        await model.place(reference, at: 8, in: store)
        XCTAssertEqual(store.project(id: project.id), saved)
        XCTAssertNotNil(model.errorMessage)
    }

    func test_audioPlacement_overflowPreservesReadyDraftAndRetryConsumesOnce() async throws {
        let (store, original) = try fixture()
        var project = original
        let draft = NarrationDraft(voiceProfileID: UUID(), text: "Ready speech", language: "english",
            filename: "draft.wav", state: .ready, duration: 8)
        try TestVideoFactory.makeToneWAV(at: store.repository.assetURL(projectID: project.id, filename: draft.filename), duration: 8)
        project.narrationDrafts = [draft]
        try store.repository.saveProjects([project])
        let reloaded = AppStore(repository: store.repository)
        let model = TimelineAudioModel()
        let reference = TimelineAudioReference(projectID: project.id, itemID: draft.id, kind: .draft,
            revision: project.revision, token: UUID())
        await model.place(reference, at: 15, in: reloaded)
        XCTAssertEqual(reloaded.project(id: project.id), project)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertThrowsError(try reloaded.undo(projectID: project.id))
        await model.place(reference, at: 8, in: reloaded)
        let placed = try XCTUnwrap(reloaded.project(id: project.id))
        XCTAssertEqual(placed.narrationDrafts[0].state, .placed)
        XCTAssertEqual(placed.narrations.filter { $0.id == draft.id }.count, 1)
        await model.place(reference, at: 0, in: reloaded)
        XCTAssertEqual(reloaded.project(id: project.id), placed)
    }

    func test_audioTrimLeft_preservesEndSourceAlignmentAndCommitsOnce() throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let layer = project.narrations[0]
        for delta in [0.25, 0.5, 1.0] {
            model.update(layerID: layer.id, adjustment: .trimStart, value: delta, project: project)
            XCTAssertEqual(store.project(id: project.id), project)
        }
        model.finish(in: store)
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.narrations[0].startTime, 3)
        XCTAssertEqual(saved.narrations[0].sourceStart, 2)
        XCTAssertEqual(saved.narrations[0].duration, 3)
        XCTAssertEqual(saved.narrations[0].endTime, layer.endTime)
        XCTAssertNotEqual(saved.narrations[0].sceneAnchor, layer.sceneAnchor)
        XCTAssertEqual(saved.revision, project.revision + 1)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations, project.narrations)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_audioTrimRight_extendsAvailableSourceWithoutMovingStart() throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let layer = project.narrations[0]
        model.update(layerID: layer.id, adjustment: .trimEnd, value: 2, project: project)
        model.finish(in: store)
        let edited = try XCTUnwrap(store.project(id: project.id)?.narrations.first)
        XCTAssertEqual(edited.duration, 6)
        XCTAssertEqual(edited.startTime, layer.startTime)
        XCTAssertEqual(edited.sourceStart, layer.sourceStart)
    }

    func test_audioTrim_invalidRangesAndCancellationPreserveProject() throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        for (operation, delta) in [(TimelineAudioModel.Adjustment.trimStart, -2.0), (.trimStart, 4), (.trimEnd, 5)] {
            model.update(layerID: project.narrations[0].id, adjustment: operation, value: delta, project: project)
            model.finish(in: store)
            XCTAssertEqual(store.project(id: project.id), project)
            XCTAssertNotNil(model.errorMessage)
        }
        model.update(layerID: project.narrations[0].id, adjustment: .trimStart, value: 1, project: project)
        model.cancelAdjustment()
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_audioAdjustments_staleRevisionAndWriteFailureLeaveHistoryUnchanged() throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let layer = project.narrations[0]
        model.update(layerID: layer.id, adjustment: .fadeIn, value: 0.5, project: project)
        var concurrent = project
        concurrent.narrations[0].name = "Changed elsewhere"
        let current = try store.saveProject(concurrent, expectedRevision: project.revision)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), current)
        _ = try store.undo(projectID: project.id)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        let restored = try XCTUnwrap(store.project(id: project.id))
        let library = store.repository.rootURL.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        model.update(layerID: layer.id, adjustment: .volume, value: 0.4, project: restored)
        model.finish(in: store)
        XCTAssertEqual(store.project(id: project.id), restored)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
    }

    func test_audioFadeAndVolume_transientChangesRespectFadeLengthAndUndo() throws {
        let (store, initial) = try fixture()
        let model = TimelineAudioModel()
        for (operation, value) in [(TimelineAudioModel.Adjustment.fadeIn, 20.0), (.fadeOut, -20), (.volume, 0.25)] {
            let project = try XCTUnwrap(store.project(id: initial.id))
            model.update(layerID: project.narrations[0].id, adjustment: operation, value: value, project: project)
            XCTAssertEqual(store.project(id: initial.id), project)
            model.finish(in: store)
        }
        let edited = try XCTUnwrap(store.project(id: initial.id)?.narrations.first)
        XCTAssertEqual(edited.fadeIn, 3)
        XCTAssertEqual(edited.fadeOut, 1)
        XCTAssertEqual(edited.volume, 0.25)
        _ = try store.undo(projectID: initial.id)
        XCTAssertEqual(store.project(id: initial.id)?.narrations[0].volume, 1)
    }

    func test_audioFade_afterTrimPreviewMatchesSavedEnvelope() throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let id = project.narrations[0].id
        model.update(layerID: id, adjustment: .trimStart, value: 0.5, project: project)
        model.finish(in: store)
        let trimmed = try XCTUnwrap(store.project(id: project.id))
        XCTAssertNotNil(trimmed.narrations[0].fadeEnvelope)
        model.update(layerID: id, adjustment: .fadeIn, value: 1, project: trimmed)
        let preview = try XCTUnwrap(model.previewLayer)
        XCTAssertEqual(preview.effectiveFadeEnvelope.gain(at: 0), 0, accuracy: 0.001)
        model.finish(in: store)
        let saved = try XCTUnwrap(store.project(id: project.id)?.narrations.first)
        for time in [0.0, 0.25, 0.75, 1.5, 3.0] {
            XCTAssertEqual(preview.effectiveFadeEnvelope.gain(at: time),
                saved.effectiveFadeEnvelope.gain(at: time), accuracy: 0.001)
        }
    }

    func test_audioDrop_oldProviderDoesNotCancelNewerDrag() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        _ = model.beginDrag(itemID: project.audioAssets[0].id, kind: .asset, project: project)
        let first = try XCTUnwrap(model.dragging)
        _ = model.beginDrag(itemID: project.audioAssets[0].id, kind: .asset, project: project)
        let second = try XCTUnwrap(model.dragging)
        await model.receiveDrop(try JSONEncoder().encode(first), reference: first, at: 4, in: store)
        XCTAssertEqual(model.dragging, second)
        XCTAssertEqual(store.project(id: project.id), project)
        await model.receiveDrop(try JSONEncoder().encode(second), reference: second, at: 8, in: store)
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
        XCTAssertEqual(store.project(id: project.id)?.narrations.last?.startTime, 8)
    }

    func test_audioAdjustments_sameRevisionAssetRegistrationSurvivesCommit() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        model.update(layerID: project.narrations[0].id, adjustment: .volume, value: 0.5, project: project)
        let input = store.repository.rootURL.appendingPathComponent("new.wav")
        try TestVideoFactory.makeToneWAV(at: input, duration: 1)
        let asset = try await store.importProjectAudio(projectID: project.id, sourceURL: input)
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision)
        model.finish(in: store)
        XCTAssertTrue(store.project(id: project.id)!.audioAssets.contains { $0.id == asset.id })
        XCTAssertEqual(store.project(id: project.id)?.narrations[0].volume, 0.5)
        _ = try store.undo(projectID: project.id)
        XCTAssertTrue(store.project(id: project.id)!.audioAssets.contains { $0.id == asset.id })
    }

    func test_audioVolume_keyboardInputCommitsAndUndoRestores() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let toolbar = AudioToolbarFixture(store: store, model: model, projectID: project.id)
        let window = host(toolbar, size: CGSize(width: 1000, height: 90))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let slider = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSSlider }.first)
        window.makeFirstResponder(slider)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.sendEvent(key)
        try await Task.sleep(for: .milliseconds(100))
        let volume = try XCTUnwrap(store.project(id: project.id)?.narrations[0].volume)
        XCTAssertGreaterThan(volume, 1)
        XCTAssertEqual(volume, 1.1, accuracy: 0.001)
        XCTAssertEqual((slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue),
            volume / 2, accuracy: 0.001)
        XCTAssertNil(model.previewLayer)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations, project.narrations)
    }

    func test_audioHandles_escapeCancelsAndRightTrimCommitsOnce() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let fixture = AudioBlockFixture(store: store, model: model, projectID: project.id)
        let window = host(fixture, size: CGSize(width: 960, height: 80))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let view = try XCTUnwrap(window.contentView)
        let point = view.convert(NSPoint(x: 284, y: view.isFlipped ? 19 : view.bounds.height - 19), to: nil)
        sendMouse(.leftMouseDown, at: point, window: window)
        sendMouse(.leftMouseDragged, at: NSPoint(x: point.x + 48, y: point.y), window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.previewLayer?.duration, 5)
        XCTAssertEqual(store.project(id: project.id), project)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(100))
        sendMouse(.leftMouseUp, at: NSPoint(x: point.x + 48, y: point.y), window: window)
        XCTAssertNil(model.previewLayer)
        XCTAssertEqual(store.project(id: project.id), project)
        XCTAssertThrowsError(try store.undo(projectID: project.id))
        sendMouse(.leftMouseDown, at: point, window: window)
        sendMouse(.leftMouseDragged, at: NSPoint(x: point.x + 48, y: point.y), window: window)
        sendMouse(.leftMouseUp, at: NSPoint(x: point.x + 48, y: point.y), window: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.project(id: project.id)?.narrations[0].duration, 5)
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 1)
        _ = try store.undo(projectID: project.id)
        XCTAssertEqual(store.project(id: project.id)?.narrations, project.narrations)
    }

    func test_audioHandles_fadeInAndFadeOutUseCorrectDragDirection() async throws {
        let (store, project) = try fixture()
        let model = TimelineAudioModel()
        let window = host(AudioBlockFixture(store: store, model: model, projectID: project.id),
            size: CGSize(width: 960, height: 80))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let view = try XCTUnwrap(window.contentView)
        for (x, y, delta) in [(150.0, 6.0, 24.0), (236.0, 29.0, -24.0)] {
            let start = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
            sendMouse(.leftMouseDown, at: start, window: window)
            sendMouse(.leftMouseDragged, at: NSPoint(x: start.x + delta, y: start.y), window: window)
            XCTAssertEqual(store.project(id: project.id)?.revision, delta > 0 ? project.revision : project.revision + 1)
            sendMouse(.leftMouseUp, at: NSPoint(x: start.x + delta, y: start.y), window: window)
            try await Task.sleep(for: .milliseconds(100))
        }
        let layer = try XCTUnwrap(store.project(id: project.id)?.narrations.first)
        XCTAssertEqual(layer.fadeIn, 1.5)
        XCTAssertEqual(layer.fadeOut, 1.5)
        XCTAssertEqual(store.project(id: project.id)?.revision, project.revision + 2)
    }

    /// Hosts the actual control with synthetic state, without opening user media.
    private func host<Content: View>(_ content: Content, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        window.orderFront(nil)
        return window
    }

    func test_audioActions_splitDuplicateMuteDeleteUseSharedValidation() throws {
        let (store, initial) = try fixture()
        let model = TimelineAudioModel()
        let id = initial.narrations[0].id
        model.perform(.split, layerID: id, at: 2, project: initial, store: store)
        XCTAssertEqual(store.project(id: initial.id), initial)
        model.perform(.split, layerID: id, at: 4, project: initial, store: store)
        let split = try XCTUnwrap(store.project(id: initial.id))
        XCTAssertEqual(split.narrations.count, 2)
        XCTAssertEqual(split.narrations[1].sourceStart, 3)
        model.perform(.duplicate, layerID: id, at: 0, project: split, store: store)
        let duplicated = try XCTUnwrap(store.project(id: initial.id))
        XCTAssertEqual(duplicated.narrations.count, 3)
        let copy = try XCTUnwrap(model.selectedLayerID)
        XCTAssertNotEqual(copy, id)
        XCTAssertEqual(duplicated.narrations.last?.startTime, 2)
        model.perform(.mute, layerID: copy, at: 0, project: duplicated, store: store)
        let muted = try XCTUnwrap(store.project(id: initial.id))
        XCTAssertTrue(muted.narrations.last!.isMuted)
        model.perform(.delete, layerID: copy, at: 0, project: muted, store: store)
        XCTAssertNil(model.selectedLayerID)
        XCTAssertEqual(store.project(id: initial.id)?.narrations.count, 2)
        _ = try store.undo(projectID: initial.id)
        XCTAssertEqual(store.project(id: initial.id)?.narrations, muted.narrations)
    }

    func test_audioUI_panelAndTrimRemainUsableInWideAndCompactWindows() async throws {
        let (store, initial) = try fixture()
        let url = store.repository.assetURL(projectID: initial.id, filename: initial.recording!.filename)
        try FileManager.default.removeItem(at: url)
        _ = try await TestVideoFactory.makeMovie(at: url, includeAudio: false, duration: 20)
        for width in [1100.0, 760.0] {
            let view = NSHostingView(rootView: ProjectWorkspaceView(store: store, projectID: initial.id)
                .frame(width: width, height: 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(350))
            NotificationCenter.default.post(name: .storybirdOpenProjectAudio, object: initial.id)
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            var canvas = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.width ?? 0) > $0.contentSize.width + 50
                    && ($0.documentView?.bounds.height ?? 0) > 150
            }?.documentView)
            let project = try XCTUnwrap(store.project(id: initial.id))
            let row = try XCTUnwrap(TimelineTrackLayout.rows(in: project).firstIndex { $0.kind == .narration })
            let y = 32.0 + Double(row) * 44 + 19
            // The resizable preview may leave this row below the visible viewport.
            try scrollAudioRow(canvas, centerY: y)
            try await Task.sleep(for: .milliseconds(150))
            let selected = canvas.convert(NSPoint(x: 190, y: canvas.isFlipped ? y : canvas.bounds.height - y), to: nil)
            sendMouse(.leftMouseDown, at: selected, window: window)
            sendMouse(.leftMouseUp, at: selected, window: window)
            try await Task.sleep(for: .milliseconds(200))
            view.layoutSubtreeIfNeeded()
            canvas = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.bounds.width ?? 0) > $0.contentSize.width + 50
                    && ($0.documentView?.bounds.height ?? 0) > 150
            }?.documentView)
            try scrollAudioRow(canvas, centerY: y)
            try await Task.sleep(for: .milliseconds(150))
            try snapshot(view, name: "audio-panel-\(Int(width))")
            let start = canvas.convert(NSPoint(x: 100, y: canvas.isFlipped ? y : canvas.bounds.height - y), to: nil)
            sendMouse(.leftMouseDown, at: start, window: window)
            for delta in [12.0, 24, 48] {
                sendMouse(.leftMouseDragged, at: NSPoint(x: start.x + delta, y: start.y), window: window)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(store.project(id: project.id), project, "Dragging must not publish.")
            }
            sendMouse(.leftMouseUp, at: NSPoint(x: start.x + 48, y: start.y), window: window)
            try await Task.sleep(for: .milliseconds(200))
            let changed = try XCTUnwrap(store.project(id: project.id))
            XCTAssertEqual(changed.narrations[0].startTime, 3, accuracy: 0.05)
            XCTAssertEqual(changed.narrations[0].sourceStart, 2, accuracy: 0.05)
            XCTAssertEqual(changed.narrations[0].duration, 3, accuracy: 0.05)
            XCTAssertEqual(changed.revision, project.revision + 1)
            try snapshot(view, name: "audio-trim-\(Int(width))")
            _ = try store.undo(projectID: project.id)
            XCTAssertEqual(store.project(id: project.id)?.narrations, project.narrations)
            if width == 1100 {
                var generated = try XCTUnwrap(store.project(id: project.id))
                generated.narrations[0].voiceProfileID = UUID()
                generated.narrations[0].text = "Synthetic speech"
                let prior = generated.revision
                try store.saveProject(generated, expectedRevision: prior)
                try await Task.sleep(for: .milliseconds(150))
                let center = canvas.convert(NSPoint(x: 190, y: canvas.isFlipped ? y : canvas.bounds.height - y), to: nil)
                for count in [1, 2] {
                    sendMouse(.leftMouseDown, at: center, window: window, clickCount: count)
                    sendMouse(.leftMouseUp, at: center, window: window, clickCount: count)
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await Task.sleep(for: .milliseconds(300))
                let sheet = try XCTUnwrap(window.attachedSheet, "Double-click must open speech editing.")
                sheet.cancelOperation(nil)
                try await Task.sleep(for: .milliseconds(250))
                _ = try store.undo(projectID: project.id)
            }
        }
    }

    /// Scrolls the outer layer viewport; the nested horizontal canvas cannot scroll vertically itself.
    private func scrollAudioRow(_ canvas: NSView, centerY: CGFloat) throws {
        var ancestor = canvas.superview
        while let current = ancestor {
            if let scroll = current as? NSScrollView, scroll.hasVerticalScroller,
               let document = scroll.documentView {
                let row = canvas.convert(NSPoint(x: 0, y: canvas.isFlipped ? centerY : canvas.bounds.height - centerY),
                    to: document)
                document.scroll(NSPoint(x: 0, y: max(0, row.y - scroll.contentSize.height / 2)))
                return
            }
            ancestor = current.superview
        }
        XCTFail("Missing vertical timeline viewport.")
    }

    /// Sends synthetic pointer events only to the isolated test window.
    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow, clickCount: Int = 1) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1)!
        window.sendEvent(event)
    }

    /// Locates the actual scrollable timeline without querying user windows.
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    /// Saves synthetic UI evidence without using the user's project library.
    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/timeline-audio-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private struct AudioToolbarFixture: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: TimelineAudioModel
    let projectID: UUID

    var body: some View {
        if let project = store.project(id: projectID), let layer = project.narrations.first {
            TimelineAudioToolbar(model: model, store: store, project: project, layer: layer,
                playhead: 3, onEditText: {}, onInspector: {})
        }
    }
}

private struct AudioBlockFixture: View {
    @ObservedObject var store: AppStore
    @ObservedObject var model: TimelineAudioModel
    @StateObject private var move = TimelineLayerDragModel()
    let projectID: UUID

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let project = store.project(id: projectID), let layer = project.narrations.first {
                TimelineAudioBlock(store: store, model: model, move: move, project: project, layer: layer,
                    canvasWidth: 960, selected: true, playhead: 3, onSelect: {}, onEditText: {},
                    onBegin: {}, onEnd: {})
            }
        }
        .coordinateSpace(name: "timeline-layer-canvas")
    }
}
