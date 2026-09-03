import AppKit
import Combine
import CoreImage
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
}

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published var isSourcePickerPresented = false
    @Published private(set) var isLoadingSources = false
    @Published private(set) var captureSources: [CaptureSource] = []

    private struct RecordedClick {
        var normalizedPoint: CGPoint
    }

    private unowned let store: AppStore
    private let frameSource = ScreenFrameSource()
    private let sampleQueue = DispatchQueue(
        label: "io.storybird.screen-frames",
        qos: .userInteractive
    )

    private var stream: SCStream?
    private var selectedFilter: SCContentFilter?
    private var selectedCaptureFrame: CGRect?
    private var projectID: UUID?
    private var currentStepID: UUID?
    private var capturedClickCount = 0
    private var clickMonitor: Any?
    private var clickQueue: [RecordedClick] = []
    private var processingTask: Task<Void, Never>?
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
            return "Record Flow"
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

    func start(projectID: UUID) {
        guard state == .idle else { return }

        let token = UUID()
        sessionToken = token
        self.projectID = projectID
        currentStepID = nil
        capturedClickCount = 0
        clickQueue.removeAll()
        frameSource.clear()
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
                await self.finishStopping(showEditor: true)
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
                await self.finishStopping(showEditor: true)
            }
        }
    }

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
                await self.finishStopping(showEditor: true)
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
                await self.finishStopping(showEditor: true)
            }
        }
    }

    func cancelSourcePicker() {
        stop()
    }

    func stop() {
        guard state.isActive, stopTask == nil else { return }
        sessionToken = nil
        startTask?.cancel()
        isSourcePickerPresented = false
        setState(.stopping)

        stopTask = Task { [weak self] in
            guard let self else { return }
            await self.finishStopping(showEditor: true)
        }
    }

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
        let captureFrame = captureFrame(
            for: filter,
            fallback: source.initialCaptureFrame
        )
        guard captureFrame.width > 0,
              captureFrame.height > 0
        else {
            throw FlowRecordingError.invalidContentSelection
        }
        selectedFilter = filter
        selectedCaptureFrame = source.initialCaptureFrame

        let configuration = SCStreamConfiguration()
        configuration.width = max(
            Int(captureFrame.width * CGFloat(filter.pointPixelScale)),
            2
        )
        configuration.height = max(
            Int(captureFrame.height * CGFloat(filter.pointPixelScale)),
            2
        )
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.shouldBeOpaque = true

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
        let firstFrame = try await waitForFrame()
        guard let projectID else { return }
        let firstStepID = try store.beginRecordedFlow(
            with: NSImage(
                cgImage: firstFrame,
                size: NSSize(width: firstFrame.width, height: firstFrame.height)
            ),
            in: projectID
        )
        currentStepID = firstStepID

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let location = event.cgEvent?.location else { return }
            Task { @MainActor [weak self] in
                self?.enqueueClick(at: location)
            }
        }
        guard clickMonitor != nil else {
            throw FlowRecordingError.clickMonitorUnavailable
        }

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

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == ownBundleID
        }
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
            let screenName = NSScreen.screens.first(where: {
                $0.displayID == display.displayID
            })?.localizedName ?? "Display \(index + 1)"
            sources.append(
                CaptureSource(
                    id: "display-\(display.displayID)",
                    kind: .display,
                    title: screenName,
                    subtitle: "Entire screen · \(Int(display.frame.width)) × \(Int(display.frame.height))",
                    thumbnail: thumbnail,
                    filter: filter,
                    initialCaptureFrame: display.frame
                )
            )
        }

        let windows = content.windows.filter { window in
            let frame = window.frame
            return window.isOnScreen
                && window.windowLayer == 0
                && frame.width >= 220
                && frame.height >= 120
                && window.owningApplication?.bundleIdentifier != ownBundleID
                && window.owningApplication?.applicationName != "Window Server"
        }

        for window in windows.prefix(30) {
            try Task.checkCancellation()
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let thumbnail = await thumbnail(
                for: filter,
                captureFrame: window.frame
            )
            let applicationName =
                window.owningApplication?.applicationName ?? "Application"
            let windowTitle = window.title?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            sources.append(
                CaptureSource(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    title: windowTitle?.isEmpty == false
                        ? windowTitle!
                        : applicationName,
                    subtitle: applicationName,
                    thumbnail: thumbnail,
                    filter: filter,
                    initialCaptureFrame: window.frame
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

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private func enqueueClick(at screenPoint: CGPoint) {
        guard case .recording = state,
              let selectedFilter,
              let selectedCaptureFrame,
              let normalizedPoint = RecordingGeometry.normalizedCaptureClick(
                  capturePoint: screenPoint,
                  captureFrame: captureFrame(
                      for: selectedFilter,
                      fallback: selectedCaptureFrame
                  )
              )
        else {
            return
        }

        clickQueue.append(RecordedClick(normalizedPoint: normalizedPoint))
        hud?.setPendingClicks(clickQueue.count)
        guard processingTask == nil else { return }

        processingTask = Task { [weak self] in
            await self?.drainClickQueue()
        }
    }

    private func drainClickQueue() async {
        while !clickQueue.isEmpty {
            let click = clickQueue.removeFirst()
            hud?.setPendingClicks(clickQueue.count)

            do {
                try await Task.sleep(for: .milliseconds(450))
                guard let image = frameSource.latestImage(),
                      let projectID,
                      let currentStepID
                else {
                    throw FlowRecordingError.noFrame
                }

                let nextStepID = try store.appendRecordedClick(
                    at: click.normalizedPoint,
                    resultingImage: NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    ),
                    from: currentStepID,
                    in: projectID
                )
                self.currentStepID = nextStepID

                capturedClickCount += 1
                if case .recording = state {
                    setState(.recording(clicks: capturedClickCount))
                }
            } catch is CancellationError {
                break
            } catch {
                store.errorMessage = "A recorded click could not be saved: \(error.localizedDescription)"
                break
            }
        }
        processingTask = nil
    }

    private func waitForFrame() async throws -> CGImage {
        for _ in 0..<30 {
            try Task.checkCancellation()
            if let image = frameSource.latestImage() {
                return image
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FlowRecordingError.noFrame
    }

    private func finishStopping(showEditor: Bool) async {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        let pendingTask = processingTask
        await pendingTask?.value
        clickQueue.removeAll()

        if let stream {
            try? await stream.stopCaptureAsync()
            self.stream = nil
        }

        frameSource.clear()
        hud?.close()
        hud = nil
        isSourcePickerPresented = false
        isLoadingSources = false
        captureSources = []

        if showEditor {
            restoreEditorWindows()
        }

        selectedFilter = nil
        selectedCaptureFrame = nil
        sessionToken = nil
        projectID = nil
        currentStepID = nil
        startTask = nil
        processingTask = nil
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

    private func captureFrame(
        for filter: SCContentFilter,
        fallback: CGRect
    ) -> CGRect {
        if #available(macOS 15.2, *) {
            if filter.style == .window,
               let window = filter.includedWindows.first {
                return window.frame
            }
            if filter.style == .display,
               let display = filter.includedDisplays.first {
                return display.frame
            }
        }
        return fallback.width > 0 && fallback.height > 0
            ? fallback
            : filter.contentRect
    }

    private func screen(containing captureFrame: CGRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.quartzFrame.intersection(captureFrame).area
                < second.quartzFrame.intersection(captureFrame).area
        }
    }

}

private final class ScreenFrameSource: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var image: CGImage?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = context.createCGImage(
            ciImage,
            from: ciImage.extent
        ) else {
            return
        }

        lock.lock()
        image = frame
        lock.unlock()
    }

    func latestImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }

    func clear() {
        lock.lock()
        image = nil
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

    var clickCount: Int {
        model.clickCount
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

    func setPendingClicks(_ count: Int) {
        model.pendingClicks = count
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
private final class RecordingHUDModel: ObservableObject {
    @Published var state: RecordingState = .preparing
    @Published var pendingClicks = 0

    var clickCount: Int {
        if case let .recording(clicks) = state {
            return clicks
        }
        return 0
    }
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
            return "Saving the last screen"
        }
    }

    private var detail: String {
        switch model.state {
        case .recording:
            return model.pendingClicks == 0
                ? "Every click becomes the next interactive step."
                : "Processing \(model.pendingClicks) queued click\(model.pendingClicks == 1 ? "" : "s")…"
        case .countdown:
            return "Bring the product you want to record to the front."
        case .stopping:
            return "Storybird will return to the editor."
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
