import AppKit
import Combine
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird

@MainActor
final class VoiceProfileCreationViewTests: XCTestCase {
    func test_languageSelection_updatesVisibleScriptAndPreservesItThroughRecordingAndSave() async throws {
        let recorder = SyntheticProfileRecorder()
        var saved: VoiceProfileCreationModel.Input?
        let model = VoiceProfileCreationModel(
            persist: { saved = $0 },
            discardSample: { recorder.discard() }
        )
        model.profileName = "Synthetic narrator"
        model.consentConfirmed = true
        let window = host(VoiceProfileCreationView(model: model, recorder: recorder))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        for language in [VoiceLanguage.korean, .english, .korean, .english] {
            model.referenceLanguage = language
            await settle()
            let text = displayedText(content)
            XCTAssertTrue(text.contains(language.referencePrompt), "The selected script must be visible.")
            let other: VoiceLanguage = language == .english ? .korean : .english
            XCTAssertFalse(text.contains(other.referencePrompt), "The previous language must not remain visible.")
            if language == .korean { try snapshot(content, name: "korean-before-recording") }
        }
        try snapshot(content, name: "english-before-recording")

        try await recorder.start(preferredDeviceUID: nil)
        await settle()
        XCTAssertTrue(displayedText(content).contains(VoiceLanguage.english.referencePrompt))
        try snapshot(content, name: "english-recording")
        recorder.pause()
        await settle()
        XCTAssertTrue(displayedText(content).contains(VoiceLanguage.english.referencePrompt))
        try recorder.resume()
        XCTAssertTrue(recorder.finish())
        await settle()
        XCTAssertTrue(displayedText(content).contains(VoiceLanguage.english.referencePrompt))
        try snapshot(content, name: "english-recording-ready")
        await model.save(recordedURL: recorder.recordedURL)
        XCTAssertEqual(saved?.language, .english)
        XCTAssertEqual(saved?.transcript, VoiceLanguage.english.referencePrompt)
    }

    func test_savingSheet_blocksCloseAndDismissesAfterSuccessfulSave() async throws {
        let recorder = SyntheticProfileRecorder()
        recorder.recordedURL = URL(fileURLWithPath: "/synthetic/ready.wav")
        var resume: CheckedContinuation<Void, Never>?
        let model = VoiceProfileCreationModel(
            persist: { _ in await withCheckedContinuation { resume = $0 } },
            discardSample: { recorder.discard() }
        )
        model.profileName = "Synthetic narrator"
        model.consentConfirmed = true
        let presentation = SyntheticSheetPresentation()
        let window = host(
            SyntheticCreationSheet(presentation: presentation, model: model, recorder: recorder)
        )
        defer { window.close() }
        presentation.isPresented = true
        try await waitFor { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let save = Task { await model.save(recordedURL: recorder.recordedURL) }
        try await waitFor { model.isSaving && resume != nil }
        await settle()
        try snapshot(sheet.contentView!, name: "saving")

        sheet.cancelOperation(nil)
        sheet.performClose(nil)
        await settle()
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(recorder.discards, 0)

        resume?.resume()
        await save.value
        try await waitFor { window.attachedSheet == nil }
        XCTAssertTrue(model.isClosed)
        XCTAssertEqual(recorder.discards, 1)
    }

    func test_activeRecording_fullPromptAndFooterRemainInScrollableSheet() async throws {
        let recorder = SyntheticProfileRecorder()
        recorder.isRecording = true
        let model = VoiceProfileCreationModel(persist: { _ in }, discardSample: { recorder.discard() })
        model.profileName = "Synthetic narrator"
        model.consentConfirmed = true
        let window = host(VoiceProfileCreationView(model: model, recorder: recorder))
        defer { window.close() }
        await settle()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.frame.size, CGSize(width: 620, height: 650))
        let scrollViews = descendants(of: content).compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrollViews.isEmpty, "Long recording content needs native scrolling.")
        try snapshot(content, name: "recording")
        for scroll in scrollViews {
            guard let document = scroll.documentView else { continue }
            document.scroll(
                NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height))
            )
        }
        content.layoutSubtreeIfNeeded()
        try snapshot(content, name: "recording-scrolled")
        model.cancel()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.discards, 1)
    }

    /// Mounts the real SwiftUI content in an isolated, offscreen AppKit window.
    private func host<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: content
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
        )
        window.orderFront(nil)
        return window
    }

    /// Waits for native sheet transitions without starting capture or synthesis.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native sheet did not reach the expected state.")
        throw CocoaError(.coderInvalidValue)
    }

    /// Gives SwiftUI a rendering turn before inspecting the mounted UI.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Finds the scroll container used by the actual macOS form.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Selectable SwiftUI scripts expose their displayed string in native text fields.
    private func displayedText(_ view: NSView) -> String {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
    }

    /// Writes only synthetic UI evidence to the generated build directory.
    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/voice-profile-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class SyntheticSheetPresentation: ObservableObject {
    @Published var isPresented = false
}

private struct SyntheticCreationSheet: View {
    @ObservedObject var presentation: SyntheticSheetPresentation
    let model: VoiceProfileCreationModel
    let recorder: SyntheticProfileRecorder

    var body: some View {
        Text("Synthetic settings")
            .frame(width: 620, height: 650)
            .sheet(isPresented: $presentation.isPresented) {
                VoiceProfileCreationView(model: model, recorder: recorder)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light)
            }
    }
}

@MainActor
private final class SyntheticProfileRecorder: VoiceSampleRecording {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordedURL: URL?
    let errorMessage: String? = nil
    let elapsedTime = 10.5
    let levelSamples = (0..<32).map { Double(($0 * 7) % 10) / 10 }
    let activeDeviceName: String? = "Synthetic microphone"
    let isUsingFallbackDevice = false
    var discards = 0
    var hasSession: Bool { isRecording || isPaused || recordedURL != nil }
    var canFinish: Bool { elapsedTime >= 10 }

    /// Simulates recording state without requesting microphone access.
    func start(preferredDeviceUID: String?) async throws { isRecording = true }
    /// Simulates pause while retaining a synthetic session.
    func pause() { isRecording = false; isPaused = true }
    /// Simulates resume without touching a device.
    func resume() throws { isRecording = true; isPaused = false }
    /// Marks a synthetic sample ready for sheet persistence tests.
    func finish() -> Bool {
        isRecording = false
        isPaused = false
        recordedURL = URL(fileURLWithPath: "/synthetic/ready.wav")
        return true
    }
    /// Records cleanup and closes every synthetic input state.
    func discard() {
        discards += 1
        isRecording = false
        isPaused = false
        recordedURL = nil
    }
}
