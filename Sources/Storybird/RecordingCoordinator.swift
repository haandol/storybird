import AppKit
import Combine
import CoreMedia
import CoreVideo
import StorybirdCore
import ScreenCaptureKit
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case preparing
    case countdown(Int)
    case recording(clicks: Int)
    case stopping

    var isActive: Bool {
        self != .idle
    }
}

enum FlowRecordingError: LocalizedError {
    case invalidContentSelection
    case noFrame
    case clickMonitorUnavailable
    case screenRecordingPermission
    case inputMonitoringPermission

    var errorDescription: String? {
        switch self {
        case .invalidContentSelection:
            return "Storybird could not determine the selected capture area."
        case .noFrame:
            return "No screen frame arrived from macOS."
        case .clickMonitorUnavailable:
            return "Storybird could not listen for clicks outside the app."
        case .screenRecordingPermission:
            return "Screen Recording permission is required."
        case .inputMonitoringPermission:
            return "Input Monitoring permission is required."
        }
    }
}

enum CaptureSourceKind {
    case display
    case window
}

struct CaptureSource: Identifiable {
    let id: String
    let kind: CaptureSourceKind
    let title: String
    let subtitle: String
    let thumbnail: NSImage?
    let filter: SCContentFilter
    let initialCaptureFrame: CGRect
    let windowID: CGWindowID?
}

final class TimedClickIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var isAccepting = false
    private var clicks: [TimedPointerClick] = []

    /// Opens one empty mouse-only event buffer for the new recording session.
    func start() {
        lock.lock()
        clicks.removeAll(keepingCapacity: true)
        isAccepting = true
        lock.unlock()
    }

    /// Rejects clicks arriving after Stop before video finalization begins.
    func stopAccepting() {
        lock.lock()
        isAccepting = false
        lock.unlock()
    }

    /// Stores one in-bounds mouse-down on the same zero-based clock as the MP4.
    @discardableResult
    func accept(
        screenPoint: CGPoint,
        captureFrame: CGRect,
        time: Double,
        button: PointerButton
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAccepting,
              time.isFinite,
              time >= 0,
              let normalizedPoint = RecordingGeometry.normalizedCaptureClick(
                  capturePoint: screenPoint,
                  captureFrame: captureFrame
              )
        else {
            return false
        }

        clicks.append(
            TimedPointerClick(
                time: time,
                x: normalizedPoint.x,
                y: normalizedPoint.y,
                button: button
            )
        )
        return true
    }

    /// Returns the accepted click sequence without allowing callers to reorder it.
    func acceptedClicks() -> [TimedPointerClick] {
        lock.lock()
        defer { lock.unlock() }
        return clicks
    }

    /// Reports the accepted event count for the recording HUD.
    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clicks.count
    }

    /// Clears session state after commit or rollback so clicks cannot leak across recordings.
    func reset() {
        lock.lock()
        isAccepting = false
        clicks.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published var isSourcePickerPresented = false
    @Published private(set) var isLoadingSources = false
    @Published private(set) var captureSources: [CaptureSource] = []

    private unowned let store: AppStore
    private var frameSource = ScreenFrameSource()
    private let clickIngress = TimedClickIngress()
    private let sampleQueue = DispatchQueue(
        label: "io.storybird.screen-frames",
        qos: .userInteractive
    )

    private var stream: SCStream?
    private var projectID: UUID?
    private var recordingFilename: String?
    private var videoWriter: ScreenVideoWriter?
    private var recordingDidBegin = false
    private var clickMonitor: Any?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var sessionToken: UUID?
    private var hiddenWindows: [NSWindow] = []
    private var hud: RecordingHUDController?

    init(store: AppStore) {
        self.store = store
    }

    var isActive: Bool {
        state.isActive
    }

    var toolbarTitle: String {
        switch state {
        case .idle:
            return "Record Video"
        case .preparing:
            return "Preparing…"
        case let .countdown(value):
            return "Starting in \(value)…"
        case let .recording(clicks):
            return "Recording \(clicks) clicks"
        case .stopping:
            return "Saving…"
        }
    }

    /// Begins source selection for one independent continuous video project.
    func start() {
        guard state == .idle else { return }

        let token = UUID()
        sessionToken = token
        clickIngress.reset()
        frameSource = ScreenFrameSource()
        projectID = nil
        recordingFilename = nil
        videoWriter = nil
        recordingDidBegin = false
        setState(.preparing)
        isSourcePickerPresented = true
        isLoadingSources = true
        captureSources = []

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadCaptureSources(token: token)
            } catch is CancellationError {
                guard self.sessionToken == token else { return }
                await self.finishStopping()
            } catch {
                guard self.sessionToken == token else { return }
                if let recordingError = error as? FlowRecordingError {
                    switch recordingError {
                    case .screenRecordingPermission:
                        self.store.permissionPrompt = RecordingPermissionPrompt(
                            kind: .screenRecording
                        )
                    case .inputMonitoringPermission:
                        self.store.permissionPrompt = RecordingPermissionPrompt(
                            kind: .inputMonitoring
                        )
                    default:
                        self.store.errorMessage = "Recording could not start: \(error.localizedDescription)"
                    }
                } else {
                    self.store.errorMessage = "Recording could not start: \(error.localizedDescription)"
                }
                await self.finishStopping()
            }
        }
    }

    /// Starts capture for the explicitly selected display or window.
    func selectCaptureSource(_ source: CaptureSource) {
        guard let token = sessionToken,
              state == .preparing
        else {
            return
        }

        isSourcePickerPresented = false
        isLoadingSources = false
        captureSources = []
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginSession(
                    source: source,
                    token: token
                )
            } catch is CancellationError {
                guard self.sessionToken == token else { return }
                await self.finishStopping()
            } catch {
                guard self.sessionToken == token else { return }
                if let recordingError = error as? FlowRecordingError {
                    switch recordingError {
                    case .inputMonitoringPermission:
                        self.store.permissionPrompt = RecordingPermissionPrompt(
                            kind: .inputMonitoring
                        )
                    default:
                        self.store.errorMessage = "Recording could not start: \(error.localizedDescription)"
                    }
                } else {
                    self.store.errorMessage = "Recording could not start: \(error.localizedDescription)"
                }
                await self.finishStopping()
            }
        }
    }

    /// Cancels source selection without creating a project or recording asset.
    func cancelSourcePicker() {
        stop()
    }

    /// Rejects new clicks and asynchronously finalizes the current video session.
    func stop() {
        guard state.isActive, stopTask == nil else { return }
        clickIngress.stopAccepting()
        sessionToken = nil
        startTask?.cancel()
        isSourcePickerPresented = false
        setState(.stopping)

        stopTask = Task { [weak self] in
            guard let self else { return }
            await self.finishStopping()
        }
    }

    /// Starts one silent encoder after permission and countdown, then binds mouse-downs to its clock.
    private func beginSession(
        source: CaptureSource,
        token: UUID
    ) async throws {
        guard CGPreflightListenEventAccess()
            || CGRequestListenEventAccess()
        else {
            throw FlowRecordingError.inputMonitoringPermission
        }

        try Task.checkCancellation()
        guard sessionToken == token else { return }

        let filter = source.filter
        let captureFrame = Self.captureFrame(for: source)
        guard captureFrame.width > 0,
              captureFrame.height > 0
        else {
            throw FlowRecordingError.invalidContentSelection
        }
        let configuration = SCStreamConfiguration()
        let contentRect = filter.contentRect.width > 0
            && filter.contentRect.height > 0
            ? filter.contentRect
            : captureFrame
        configuration.width = max(
            Int(contentRect.width * CGFloat(filter.pointPixelScale)),
            2
        )
        configuration.height = max(
            Int(contentRect.height * CGFloat(filter.pointPixelScale)),
            2
        )
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = source.kind == .window

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(
            frameSource,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        self.stream = stream
        try await stream.startCaptureAsync()
        try Task.checkCancellation()
        guard sessionToken == token else { return }

        hideEditorWindows()
        guard let hudScreen = screen(containing: captureFrame)
            ?? NSScreen.main
        else {
            throw FlowRecordingError.invalidContentSelection
        }
        showHUD(on: hudScreen)

        for value in stride(from: 3, through: 1, by: -1) {
            guard sessionToken == token else { return }
            setState(.countdown(value))
            try await Task.sleep(for: .seconds(1))
        }

        guard sessionToken == token else { return }
        let projectID = UUID()
        let recordingTarget = try store.repository.prepareVideoRecordingURL(
            projectID: projectID
        )
        let writer = try ScreenVideoWriter(outputURL: recordingTarget.url)
        self.projectID = projectID
        recordingFilename = recordingTarget.filename
        videoWriter = writer
        frameSource.setVideoWriter(writer)

        _ = try await waitForRecordingStart(
            writer: writer,
            fallbackCaptureFrame: captureFrame
        )

        clickIngress.start()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  let location = event.cgEvent?.location,
                  let time = self.videoWriter?.recordingTime(
                      atEventSeconds: event.timestamp
                  ),
                  let frame = self.frameSource.latestFrame(
                      fallbackCaptureFrame: Self.captureFrame(for: source)
                  )
            else {
                return
            }
            guard self.clickIngress.accept(
                screenPoint: location,
                captureFrame: frame.captureFrame,
                time: time,
                button: event.type == .rightMouseDown ? .right : .left
            ) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let count = self.clickIngress.count()
                self.setState(.recording(clicks: count))
            }
        }
        guard clickMonitor != nil else {
            throw FlowRecordingError.clickMonitorUnavailable
        }

        recordingDidBegin = true
        setState(.recording(clicks: 0))
        startTask = nil
    }

    private func loadCaptureSources(token: UUID) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw FlowRecordingError.screenRecordingPermission
            }
            throw error
        }

        try Task.checkCancellation()
        guard sessionToken == token else { return }

        let ownApplications = CaptureSourceCatalog.excludedApplications(
            in: content
        )
        var sources: [CaptureSource] = []

        for (index, display) in content.displays.enumerated() {
            try Task.checkCancellation()
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let thumbnail = await thumbnail(
                for: filter,
                captureFrame: display.frame
            )
            let screenName = CaptureSourceCatalog.displayTitle(
                displayID: display.displayID,
                fallbackIndex: index
            )
            sources.append(
                CaptureSource(
                    id: "display-\(display.displayID)",
                    kind: .display,
                    title: screenName,
                    subtitle: "Entire screen · \(Int(display.frame.width)) × \(Int(display.frame.height))",
                    thumbnail: thumbnail,
                    filter: filter,
                    initialCaptureFrame: display.frame,
                    windowID: nil
                )
            )
        }

        for window in CaptureSourceCatalog.ordinaryWindows(in: content)
            .prefix(CaptureSourceCatalog.maximumWindowCount) {
            try Task.checkCancellation()
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let thumbnail = await thumbnail(
                for: filter,
                captureFrame: window.frame
            )
            let presentation = CaptureSourceCatalog.windowPresentation(
                title: window.title,
                applicationName:
                    window.owningApplication?.applicationName
            )
            sources.append(
                CaptureSource(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    title: presentation.title,
                    subtitle: presentation.applicationName,
                    thumbnail: thumbnail,
                    filter: filter,
                    initialCaptureFrame: window.frame,
                    windowID: window.windowID
                )
            )
        }

        guard sessionToken == token else { return }
        captureSources = sources
        isLoadingSources = false
        startTask = nil
    }

    private func thumbnail(
        for filter: SCContentFilter,
        captureFrame: CGRect
    ) async -> NSImage? {
        guard captureFrame.width > 0, captureFrame.height > 0 else {
            return nil
        }

        let maximumSize = CGSize(width: 420, height: 240)
        let scale = min(
            maximumSize.width / captureFrame.width,
            maximumSize.height / captureFrame.height,
            1
        )
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(captureFrame.width * scale), 2)
        configuration.height = max(Int(captureFrame.height * scale), 2)
        configuration.showsCursor = false
        configuration.shouldBeOpaque = true
        configuration.ignoreShadowsSingleWindow = filter.style == .window

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else {
            return nil
        }
        return image.storybirdImage
    }

    /// Waits for a post-countdown frame that has entered both preview and the video encoder.
    private func waitForRecordingStart(
        writer: ScreenVideoWriter,
        fallbackCaptureFrame: CGRect
    ) async throws -> CapturedFrameSnapshot {
        for _ in 0..<30 {
            try Task.checkCancellation()
            if writer.currentTime() != nil,
               let frame = frameSource.latestFrame(
                   fallbackCaptureFrame: fallbackCaptureFrame
               ) {
                return frame
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FlowRecordingError.noFrame
    }

    /// Stops input before capture and publishes only a fully finalized, validated video project.
    private func finishStopping() async {
        clickIngress.stopAccepting()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        var captureStopError: Error?
        if let stream {
            do {
                try await stream.stopCaptureAsync()
            } catch {
                captureStopError = error
            }
            self.stream = nil
        }

        if recordingDidBegin,
           captureStopError == nil,
           let writer = videoWriter,
           let projectID,
           let recordingFilename {
            do {
                let result = try await writer.finish()
                try store.commitRecordedVideo(
                    projectID: projectID,
                    name: "Recorded video",
                    filename: recordingFilename,
                    result: result,
                    clicks: clickIngress.acceptedClicks()
                )
            } catch {
                writer.cancel()
                try? store.repository.removeProjectAssets(
                    projectID: projectID
                )
                store.errorMessage =
                    "Recording could not be saved: \(error.localizedDescription)"
            }
        } else {
            videoWriter?.cancel()
            if let projectID {
                try? store.repository.removeProjectAssets(
                    projectID: projectID
                )
            }
            if let captureStopError {
                store.errorMessage =
                    "Recording could not be finalized: \(captureStopError.localizedDescription)"
            }
        }

        frameSource.clear()
        hud?.close()
        hud = nil
        isSourcePickerPresented = false
        isLoadingSources = false
        captureSources = []

        restoreEditorWindows()

        clickIngress.reset()
        sessionToken = nil
        projectID = nil
        recordingFilename = nil
        videoWriter = nil
        recordingDidBegin = false
        startTask = nil
        stopTask = nil
        setState(.idle)
    }

    private func hideEditorWindows() {
        hiddenWindows = NSApp.windows.filter {
            $0.isVisible && !($0 is NSPanel)
        }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    private func restoreEditorWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in hiddenWindows {
            window.makeKeyAndOrderFront(nil)
        }
        hiddenWindows.removeAll()
    }

    private func showHUD(on screen: NSScreen) {
        let hud = RecordingHUDController { [weak self] in
            self?.stop()
        }
        self.hud = hud
        hud.show(on: screen)
        hud.update(state: state)
    }

    private func setState(_ state: RecordingState) {
        self.state = state
        hud?.update(state: state)
    }

    /// Resolves current window movement before falling back to selection time.
    private nonisolated static func captureFrame(
        for source: CaptureSource
    ) -> CGRect {
        let filter = source.filter
        var liveFrame = source.windowID.flatMap(
            CaptureFrameGeometry.currentWindowFrame(windowID:)
        )
        if #available(macOS 15.2, *) {
            if filter.style == .window,
               let window = filter.includedWindows.first {
                liveFrame = window.frame
            }
            if filter.style == .display,
               let display = filter.includedDisplays.first {
                liveFrame = display.frame
            }
        }
        let fallback = source.initialCaptureFrame.width > 0
            && source.initialCaptureFrame.height > 0
            ? source.initialCaptureFrame
            : filter.contentRect
        return CaptureFrameGeometry.preferredFrame(
            sampleFrame: nil,
            liveWindowFrame: liveFrame,
            fallbackFrame: fallback
        )
    }

    private func screen(containing captureFrame: CGRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.quartzFrame.intersection(captureFrame).area
                < second.quartzFrame.intersection(captureFrame).area
        }
    }

}

private struct CapturedFrameSnapshot: Sendable {
    let captureFrame: CGRect
}

private final class ScreenFrameSource: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var snapshot: CapturedFrameSnapshot?
    private var videoWriter: ScreenVideoWriter?

    /// Starts forwarding subsequent frames to the session-owned video encoder.
    func setVideoWriter(_ writer: ScreenVideoWriter) {
        lock.lock()
        videoWriter = writer
        lock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else {
            return
        }

        lock.lock()
        let writer = videoWriter
        lock.unlock()
        writer?.append(sampleBuffer)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let captureFrame = (
            attachments?.first?[.screenRect] as? NSValue
        )?.rectValue

        lock.lock()
        snapshot = CapturedFrameSnapshot(
            captureFrame: captureFrame ?? .zero
        )
        lock.unlock()
    }

    /// Returns pixels and their same-sample screen rect under one lock.
    func latestFrame(
        fallbackCaptureFrame: CGRect
    ) -> CapturedFrameSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot else { return nil }
        return CapturedFrameSnapshot(
            captureFrame: CaptureFrameGeometry.preferredFrame(
                sampleFrame: snapshot.captureFrame,
                liveWindowFrame: nil,
                fallbackFrame: fallbackCaptureFrame
            )
        )
    }

    func clear() {
        lock.lock()
        snapshot = nil
        videoWriter = nil
        lock.unlock()
    }
}

@MainActor
enum RecordingHUDLayout {
    static let topInset: CGFloat = 96

    static func initialOrigin(
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let maximumX = max(
            visibleFrame.minX,
            visibleFrame.maxX - panelSize.width
        )
        let centeredX = visibleFrame.midX - panelSize.width / 2
        let x = min(max(centeredX, visibleFrame.minX), maximumX)

        let maximumY = max(
            visibleFrame.minY,
            visibleFrame.maxY - panelSize.height
        )
        let preferredY = visibleFrame.maxY - panelSize.height - topInset
        let y = min(max(preferredY, visibleFrame.minY), maximumY)

        return CGPoint(x: x, y: y)
    }
}

@MainActor
private final class RecordingHUDController {
    private let model = RecordingHUDModel()
    private let panel: NSPanel

    init(onStop: @escaping () -> Void) {
        let view = RecordingHUDView(model: model, onStop: onStop)
        let controller = NSHostingController(rootView: view)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
    }

    func show(on screen: NSScreen) {
        panel.setFrameOrigin(
            RecordingHUDLayout.initialOrigin(
                panelSize: panel.frame.size,
                visibleFrame: screen.visibleFrame
            )
        )
        panel.orderFrontRegardless()
    }

    func update(state: RecordingState) {
        model.state = state
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
private final class RecordingHUDModel: ObservableObject {
    @Published var state: RecordingState = .preparing
}

private struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.2))
                    .frame(width: 30, height: 30)
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonTitle, action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 16)
        .frame(width: 330, height: 66)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.22))
        )
    }

    private var indicatorColor: Color {
        switch model.state {
        case .recording:
            return .red
        default:
            return Color(hex: "#5B5CE2")
        }
    }

    private var title: String {
        switch model.state {
        case .idle:
            return "Recording finished"
        case .preparing:
            return "Preparing recorder"
        case let .countdown(value):
            return "Recording starts in \(value)"
        case let .recording(clicks):
            return "\(clicks) click\(clicks == 1 ? "" : "s") captured"
        case .stopping:
            return "Finalizing video"
        }
    }

    private var detail: String {
        switch model.state {
        case .recording:
            return "Video and clicks share the same recording timeline."
        case .countdown:
            return "Bring the product you want to record to the front."
        case .stopping:
            return "Storybird will open the timeline after the MP4 is complete."
        default:
            return "Choose the product window during the countdown."
        }
    }

    private var buttonTitle: String {
        switch model.state {
        case .recording, .stopping:
            return "Stop"
        default:
            return "Cancel"
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    var quartzFrame: CGRect {
        guard let displayID else { return .zero }
        return CGDisplayBounds(displayID)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return width * height
    }
}

private extension CGImage {
    var storybirdImage: NSImage {
        NSImage(
            cgImage: self,
            size: NSSize(width: width, height: height)
        )
    }
}

private extension SCStream {
    @MainActor
    func startCaptureAsync() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    func stopCaptureAsync() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            stopCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
