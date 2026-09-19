import AppKit
import AVFAudio
import Combine
import Foundation
import StorybirdCore
import SwiftUI
@testable import Storybird
import XCTest

@MainActor
final class AudioAuditionTests: XCTestCase {
    func test_stopWhileIdle_doesNotPublishAnotherEditorUpdate() {
        let model = AudioAuditionPlayer { _ in AuditionTestPlayback() }
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        model.stop()
        model.stop()
        XCTAssertEqual(updates, 0, "A replayed video state must not trigger another editor render.")
        withExtendedLifetime(subscription) {}
    }

    func test_projectAudioButton_togglesStopAndReturnsToListenWhenFinished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let asset = ProjectAudioAsset(filename: "sound.wav", name: "Test sound", duration: 1, origin: .imported)
        var project = DemoProject(name: "Audition", recording: VideoRecordingAsset(
            filename: "video.mp4", duration: 5, width: 64, height: 48))
        project.audioAssets = [asset]
        _ = try repository.prepareVideoRecordingURL(projectID: project.id)
        try TestVideoFactory.makeToneWAV(
            at: repository.assetURL(projectID: project.id, filename: asset.filename), duration: 1
        )
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let device = AuditionTestPlayback()
        let model = AudioAuditionPlayer { _ in device }
        let view = NSHostingView(rootView: TimelineAudioPanel(
            store: store, model: TimelineAudioModel(), audition: model, projectID: project.id, playhead: 0
        ).frame(width: 320, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { model.stop(); window.close() }
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(view, name: "listen-before")
        pressListen(view, window: window)
        try await Task.sleep(for: .milliseconds(50))
        try await prepared(model)
        XCTAssertEqual(model.activeID, .item(asset.id))
        try snapshot(view, name: "listen-playing")
        device.onCompletion?(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.activeID)
        try snapshot(view, name: "listen-finished")
        pressListen(view, window: window)
        try await Task.sleep(for: .milliseconds(50))
        try await prepared(model)
        pressListen(view, window: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.activeID)
    }

    func test_silentNativePlayback_naturalCompletionReturnsToIdle() async throws {
        guard ProcessInfo.processInfo.environment["STORYBIRD_RUN_AUDIO_AUDITION"] == "1" else {
            throw XCTSkip("Set STORYBIRD_RUN_AUDIO_AUDITION=1 to exercise the native audio output with silence.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4_800)
            try file.write(from: buffer)
        }
        let model = AudioAuditionPlayer()
        defer { model.stop() }
        model.toggleFile(id: UUID(), url: url)
        try await prepared(model)
        XCTAssertNotNil(model.activeID)
        for _ in 0..<300 where model.activeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.activeID)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_naturalCompletion_resetsListenAndAllowsReplay() async throws {
        let device = AuditionTestPlayback()
        let model = AudioAuditionPlayer { _ in device }
        let id = UUID()
        model.toggleFile(id: id, url: URL(fileURLWithPath: "/unused.wav"))
        try await prepared(model)
        XCTAssertEqual(model.activeID, .item(id))
        device.onCompletion?(nil)
        XCTAssertNil(model.activeID)
        model.toggleFile(id: id, url: URL(fileURLWithPath: "/unused.wav"))
        try await prepared(model)
        XCTAssertEqual(device.playCount, 2)
        model.stop()
    }

    func test_stopAndSwitchItem_ignoreLateCompletionFromPreviousPlayer() async throws {
        let first = AuditionTestPlayback()
        let second = AuditionTestPlayback()
        var devices = [first, second]
        let model = AudioAuditionPlayer { _ in devices.removeFirst() }
        let firstID = UUID(), secondID = UUID()
        model.toggleFile(id: firstID, url: URL(fileURLWithPath: "/first.wav"))
        try await prepared(model)
        let lateCompletion = first.onCompletion
        model.toggleFile(id: secondID, url: URL(fileURLWithPath: "/second.wav"))
        try await prepared(model)
        XCTAssertEqual(first.stopCount, 1)
        lateCompletion?("Old decode error")
        XCTAssertEqual(model.activeID, .item(secondID))
        XCTAssertNil(model.errorMessage)
        model.toggleFile(id: secondID, url: URL(fileURLWithPath: "/second.wav"))
        XCTAssertNil(model.activeID)
        XCTAssertEqual(second.stopCount, 1)
    }

    func test_completionDeletesTemporaryPreviewButPreservesSourceFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sound.wav")
        let device = AuditionTestPlayback()
        let model = AudioAuditionPlayer { _ in device }
        for temporary in [false, true] {
            try Data([1, 2]).write(to: file)
            model.toggle(id: .layer(UUID())) { .init(url: file, temporary: temporary) }
            try await prepared(model)
            device.onCompletion?(nil)
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), !temporary)
            XCTAssertNil(model.activeID)
        }
    }

    func test_cancelledPreparation_discardsLateResultWithoutStartingPlayback() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        let pending = AuditionSuspendedPreparation()
        let device = AuditionTestPlayback()
        let model = AudioAuditionPlayer { _ in device }
        let id = AudioAuditionID.layer(UUID())
        model.toggle(id: id) { await pending.wait() }
        for _ in 0..<100 where !(await pending.started) { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(model.isPreparing)
        model.toggle(id: id) { .init(url: file) }
        XCTAssertNil(model.activeID)
        await pending.finish(.init(url: file, temporary: true))
        for _ in 0..<100 where FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(device.playCount, 0)
    }

    func test_playbackFailure_resetsStateShowsErrorAndAllowsRetry() async throws {
        let device = AuditionTestPlayback()
        device.canPlay = false
        let model = AudioAuditionPlayer { _ in device }
        let id = UUID()
        model.toggleFile(id: id, url: URL(fileURLWithPath: "/unused.wav"))
        try await prepared(model)
        XCTAssertNil(model.activeID)
        XCTAssertNotNil(model.errorMessage)
        device.canPlay = true
        model.toggleFile(id: id, url: URL(fileURLWithPath: "/unused.wav"))
        try await prepared(model)
        XCTAssertEqual(model.activeID, .item(id))
        XCTAssertNil(model.errorMessage)
        device.onCompletion?("Decode failed")
        XCTAssertNil(model.activeID)
        XCTAssertEqual(model.errorMessage, "Decode failed")
    }

    func test_panelCleanup_stopsOnlyItsOwnAudition() async throws {
        let device = AuditionTestPlayback()
        let model = AudioAuditionPlayer { _ in device }
        let layer = UUID()
        model.toggle(id: .layer(layer)) { .init(url: URL(fileURLWithPath: "/unused.wav")) }
        try await prepared(model)
        model.stopItems()
        model.stop(id: .layer(UUID()))
        XCTAssertEqual(model.activeID, .layer(layer))
        model.stop(id: .layer(layer))
        XCTAssertNil(model.activeID)
    }

    private func prepared(_ model: AudioAuditionPlayer) async throws {
        for _ in 0..<100 where model.isPreparing { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(model.isPreparing)
    }

    /// Coordinates are from the reviewed 320×520 synthetic panel screenshot.
    /// Events stay in this offscreen test window; no desktop pointer is moved.
    private func pressListen(_ view: NSView, window: NSWindow) {
        let point = view.convert(NSPoint(x: 60, y: view.isFlipped ? 202 : view.bounds.height - 202), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!)
        }
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/audio-audition")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("\(name).png"))
    }
}

@MainActor
final class AuditionTestPlayback: AudioAuditionPlayback {
    var onCompletion: ((String?) -> Void)?
    var canPlay = true
    private(set) var playCount = 0
    private(set) var stopCount = 0
    func play() -> Bool { playCount += 1; return canPlay }
    func stop() { stopCount += 1 }
}

private actor AuditionSuspendedPreparation {
    private var continuation: CheckedContinuation<AudioAuditionPlayer.PreparedAudio, Never>?
    var started: Bool { continuation != nil }
    func wait() async -> AudioAuditionPlayer.PreparedAudio {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ audio: AudioAuditionPlayer.PreparedAudio) {
        continuation?.resume(returning: audio)
        continuation = nil
    }
}
