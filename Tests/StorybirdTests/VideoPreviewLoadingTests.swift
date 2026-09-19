import AppKit
import AVKit
import StorybirdCore
import SwiftUI
@testable import Storybird
import XCTest

@MainActor
final class VideoPreviewLoadingTests: XCTestCase {
    func test_metadataReadinessAlone_keepsTheLoadingCover() {
        XCTAssertEqual(VideoPreviewPhase.resolve(
            isPreparing: false, itemStatus: .readyToPlay, isReadyForDisplay: false, errorMessage: nil
        ), .loading)
        XCTAssertEqual(VideoPreviewPhase.resolve(
            isPreparing: true, itemStatus: .readyToPlay, isReadyForDisplay: true, errorMessage: nil
        ), .loading)
        XCTAssertEqual(VideoPreviewPhase.resolve(
            isPreparing: false, itemStatus: .readyToPlay, isReadyForDisplay: true, errorMessage: nil
        ), .ready)
        XCTAssertEqual(VideoPreviewPhase.resolve(
            isPreparing: false, itemStatus: .failed, isReadyForDisplay: true, errorMessage: "Cannot read video"
        ), .failed("Cannot read video"))
    }

    func test_loadingCover_waitsForPreparationAndFirstFrameWithoutUnmountingPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("video.mp4")
        _ = try await TestVideoFactory.makeMovie(at: url, includeAudio: false)
        let probe = LoadingProbe()
        let (view, window) = host(probe)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(probe.phase, .loading)
        XCTAssertEqual(surfaces(view).count, 1, "The player must stay mounted under the cover.")
        try snapshot(view, name: "loading")
        probe.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let surface = try XCTUnwrap(surfaces(view).first)
        for _ in 0..<100 where !surface.isReadyForDisplay {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(surface.isReadyForDisplay)
        XCTAssertEqual(probe.phase, .loading, "An old/ready surface must not override ongoing preparation.")
        probe.preparing = false
        try await wait(probe, until: { $0 == .ready })
        XCTAssertEqual(surfaces(view).count, 1)
        XCTAssertEqual(surface.player?.rate, 0)
        try snapshot(view, name: "ready")
        probe.player.replaceCurrentItem(with: nil)
        try await wait(probe, until: { $0 == .empty })
        XCTAssertEqual(probe.phase, .empty, "An empty timeline must not spin forever.")
    }

    func test_failedItem_replacesLoadingWithAnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("broken.mp4")
        try Data("not a movie".utf8).write(to: url)
        let probe = LoadingProbe()
        probe.preparing = false
        probe.player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let (view, window) = host(probe)
        defer { window.close() }
        try await wait(probe, until: { if case .failed = $0 { true } else { false } })
        if case let .failed(message) = probe.phase { XCTAssertFalse(message.isEmpty) }
        else { XCTFail("A failed item must show an error, not a permanent spinner.") }
        try snapshot(view, name: "failed")
    }

    func test_detachedSurface_cannotPublishItsQueuedReadinessIntoAnotherSurface() async throws {
        let coordinator = VideoPlayerSurface.Coordinator()
        let oldView = AVPlayerView(), newView = AVPlayerView()
        let oldPlayer = AVPlayer(), newPlayer = AVPlayer()
        oldView.player = oldPlayer
        newView.player = newPlayer
        var oldEvents: [VideoPreviewPhase] = []
        var newEvents: [VideoPreviewPhase] = []
        coordinator.bind(view: oldView, player: oldPlayer, isPreparing: true) { oldEvents.append($0) }
        coordinator.bind(view: newView, player: newPlayer, isPreparing: false) { newEvents.append($0) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(oldEvents.isEmpty)
        XCTAssertEqual(newEvents, [.empty])
        coordinator.invalidate()
        oldPlayer.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/unused.mp4")))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(oldEvents.isEmpty)
        XCTAssertEqual(newEvents, [.empty])
    }

    private func wait(_ probe: LoadingProbe, until condition: (VideoPreviewPhase) -> Bool) async throws {
        for _ in 0..<150 where !condition(probe.phase) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(probe.phase), "Observed phase: \(probe.phase)")
    }

    private func host(_ probe: LoadingProbe) -> (NSView, NSWindow) {
        let view = NSHostingView(rootView: LoadingFixture(probe: probe)
            .frame(width: 480, height: 280)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 480, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        return (view, window)
    }

    private func surfaces(_ view: NSView) -> [AVPlayerView] {
        view.subviews.flatMap { child in (child as? AVPlayerView).map { [$0] } ?? surfaces(child) }
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/video-preview-loading")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class LoadingProbe: ObservableObject {
    let player = AVPlayer()
    @Published var preparing = true
    @Published var phase: VideoPreviewPhase = .loading
}

private struct LoadingFixture: View {
    @ObservedObject var probe: LoadingProbe
    var body: some View {
        ZStack {
            VideoPlayerSurface(player: probe.player, isPreparing: probe.preparing) { phase in
                if probe.phase != phase { probe.phase = phase }
            }
            if probe.phase != .ready { VideoPreviewPlaceholder(phase: probe.phase) }
        }
    }
}
