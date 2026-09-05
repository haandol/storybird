import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import StorybirdCore
import StorybirdMCPKit

/// Privileged ScreenCaptureKit and pointer implementation owned by Storybird.app.
final class ScreenCaptureDesktopPlatform: StorybirdDesktopPlatform, @unchecked Sendable {
    /// Enumerates display and ordinary window sources without changing focus.
    func listSources() async throws -> [StorybirdMCPSourceDescriptor] {
        let content = try await shareableContent()
        var sources: [StorybirdMCPSourceDescriptor] = []

        for (index, display) in content.displays.enumerated() {
            let screenName = CaptureSourceCatalog.displayTitle(
                displayID: display.displayID,
                fallbackIndex: index
            )
            sources.append(
                StorybirdMCPSourceDescriptor(
                    id: "display-\(display.displayID)",
                    kind: .display,
                    title: screenName,
                    subtitle: "Entire screen",
                    width: display.frame.width,
                    height: display.frame.height
                )
            )
        }

        for window in CaptureSourceCatalog.ordinaryWindows(in: content)
            .prefix(CaptureSourceCatalog.maximumWindowCount) {
            let presentation = CaptureSourceCatalog.windowPresentation(
                title: window.title,
                applicationName:
                    window.owningApplication?.applicationName
            )
            sources.append(
                StorybirdMCPSourceDescriptor(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    title: presentation.title,
                    subtitle: presentation.applicationName,
                    width: window.frame.width,
                    height: window.frame.height
                )
            )
        }
        return sources
    }

    /// Resolves a fresh source object and starts capture only after pointer access.
    func startSession(
        sourceID: String,
        recordingURL: URL
    ) async throws -> any StorybirdDesktopSession {
        let content = try await shareableContent()
        let filter: SCContentFilter
        let frame: CGRect
        let descriptor: StorybirdMCPSourceDescriptor
        let windowID: CGWindowID?

        if let displayID = Self.numericID(
            sourceID,
            prefix: "display-"
        ), let display = content.displays.first(where: {
            $0.displayID == displayID
        }) {
            filter = SCContentFilter(
                display: display,
                excludingApplications:
                    CaptureSourceCatalog.excludedApplications(in: content),
                exceptingWindows: []
            )
            frame = display.frame
            windowID = nil
            descriptor = StorybirdMCPSourceDescriptor(
                id: sourceID,
                kind: .display,
                title: CaptureSourceCatalog.displayTitle(
                    displayID: display.displayID,
                    fallbackIndex: nil
                ),
                subtitle: "Entire screen",
                width: frame.width,
                height: frame.height
            )
        } else if let parsedWindowID = Self.numericID(
            sourceID,
            prefix: "window-"
        ), let window = CaptureSourceCatalog.ordinaryWindows(
            in: content
        ).first(where: {
            $0.windowID == parsedWindowID
        }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            frame = window.frame
            windowID = window.windowID
            let presentation = CaptureSourceCatalog.windowPresentation(
                title: window.title,
                applicationName:
                    window.owningApplication?.applicationName
            )
            descriptor = StorybirdMCPSourceDescriptor(
                id: sourceID,
                kind: .window,
                title: presentation.title,
                subtitle: presentation.applicationName,
                width: frame.width,
                height: frame.height
            )
        } else {
            throw StorybirdMCPError.sourceNotFound
        }

        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw StorybirdMCPError.pointerControlPermission
        }

        let session = ScreenCaptureDesktopSession(
            descriptor: descriptor,
            filter: filter,
            initialCaptureFrame: frame,
            windowID: windowID,
            videoWriter: try ScreenVideoWriter(outputURL: recordingURL)
        )
        try await session.start()
        return session
    }

    /// Attempts the real ScreenCaptureKit request before classifying TCC failure.
    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !CGPreflightScreenCaptureAccess() {
                throw StorybirdMCPError.screenRecordingPermission
            }
            throw error
        }
    }

    /// Parses a source identifier without accepting signs or trailing text.
    private static func numericID(
        _ value: String,
        prefix: String
    ) -> UInt32? {
        guard value.hasPrefix(prefix) else { return nil }
        return UInt32(value.dropFirst(prefix.count))
    }
}

private final class StorybirdFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    private var captureFrame: CGRect = .zero
    private var sequence: UInt64 = 0

    /// Replaces the latest frame and advances the monotonic observation sequence.
    func update(_ image: CGImage, captureFrame: CGRect) {
        lock.lock()
        self.image = image
        self.captureFrame = captureFrame
        sequence &+= 1
        lock.unlock()
    }

    /// Returns a stable image reference and sequence under one lock acquisition.
    func snapshot() -> (
        image: CGImage,
        captureFrame: CGRect,
        sequence: UInt64
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard let image else { return nil }
        return (image, captureFrame, sequence)
    }

    /// Drops the last frame when a session stops so stale pixels cannot be returned.
    func clear() {
        lock.lock()
        image = nil
        captureFrame = .zero
        lock.unlock()
    }
}

private final class ScreenCaptureDesktopSession:
    NSObject,
    StorybirdDesktopSession,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable
{
    private let descriptor: StorybirdMCPSourceDescriptor
    private let filter: SCContentFilter
    private let initialCaptureFrame: CGRect
    private let windowID: CGWindowID?
    private let frames = StorybirdFrameStore()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sampleQueue = DispatchQueue(
        label: "io.storybird.mcp.screen-frames",
        qos: .userInteractive
    )
    private let stopLock = NSLock()
    private var stream: SCStream?
    private var hasStopped = false
    private var streamFailure: Error?
    private let videoWriter: ScreenVideoWriter

    init(
        descriptor: StorybirdMCPSourceDescriptor,
        filter: SCContentFilter,
        initialCaptureFrame: CGRect,
        windowID: CGWindowID?,
        videoWriter: ScreenVideoWriter
    ) {
        self.descriptor = descriptor
        self.filter = filter
        self.initialCaptureFrame = initialCaptureFrame
        self.windowID = windowID
        self.videoWriter = videoWriter
    }

    /// Starts one cursor-visible stream and waits until a real frame arrives.
    func start() async throws {
        let frame = currentCaptureFrame()
        guard frame.width > 0, frame.height > 0 else {
            throw StorybirdMCPError.sourceNotFound
        }
        let configuration = SCStreamConfiguration()
        let contentRect = filter.contentRect.width > 0
            && filter.contentRect.height > 0
            ? filter.contentRect
            : frame
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
        configuration.ignoreShadowsSingleWindow = descriptor.kind == .window

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        self.stream = stream
        try await stream.startCaptureAsync()
        _ = try await waitForFrame(after: nil, timeoutMilliseconds: 3_000)
    }

    /// Keeps the selected source identity fixed for the whole session.
    func sourceDescriptor() async -> StorybirdMCPSourceDescriptor {
        descriptor
    }

    /// Encodes the latest selected-source frame as metadata-free PNG.
    func latestFrame() async throws -> StorybirdMCPFrame {
        guard let snapshot = frames.snapshot() else {
            throw StorybirdMCPError.noFrame
        }
        return try Self.frame(from: snapshot)
    }

    /// Moves the cursor along visible intermediate points before returning a fresh frame.
    func movePointer(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws -> StorybirdMCPFrame {
        let sequence = frames.snapshot()?.sequence
        try await postPointerMove(
            x: x,
            y: y,
            durationMilliseconds: durationMilliseconds
        )
        return try await waitForFrame(
            after: sequence,
            timeoutMilliseconds: 1_000
        )
    }

    /// Posts one down/up pair at the normalized point and waits for the result.
    func click(
        x: Double,
        y: Double,
        button: StorybirdMCPPointerButton
    ) async throws -> StorybirdMCPClickResult {
        let point = try screenPoint(x: x, y: y)
        let sequence = frames.snapshot()?.sequence
        let mouseButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType =
            button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType =
            button == .left ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: upType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else {
            throw StorybirdMCPError.pointerEventFailed
        }
        let eventSeconds = ProcessInfo.processInfo.systemUptime
        guard let recordingTime = videoWriter.recordingTime(
            atEventSeconds: eventSeconds
        ) else {
            throw StorybirdMCPError.noFrame
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(450))
        do {
            return StorybirdMCPClickResult(
                frame: try await waitForFrame(
                    after: sequence,
                    timeoutMilliseconds: 1_500
                ),
                recordingTime: recordingTime,
                observedFreshFrame: true
            )
        } catch StorybirdMCPError.noFrame {
            return StorybirdMCPClickResult(
                frame: try await latestFrame(),
                recordingTime: recordingTime,
                observedFreshFrame: false
            )
        }
    }

    /// Moves to the requested point, posts one pixel wheel event, and observes its result.
    func scroll(
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) async throws -> StorybirdMCPFrame {
        try await postPointerMove(
            x: x,
            y: y,
            durationMilliseconds: 160
        )
        let sequence = frames.snapshot()?.sequence
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Self.clampedInt32(deltaY),
            wheel2: Self.clampedInt32(deltaX),
            wheel3: 0
        ) else {
            throw StorybirdMCPError.pointerEventFailed
        }
        event.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(180))
        return try await waitForFrame(
            after: sequence,
            timeoutMilliseconds: 1_000
        )
    }

    /// Posts visible intermediate pointer positions without encoding a discarded PNG.
    private func postPointerMove(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws {
        let target = try screenPoint(x: x, y: y)
        let current = CGEvent(source: nil)?.location ?? target
        let stepCount = max(durationMilliseconds / 16, 1)
        for index in 1...stepCount {
            let progress = CGFloat(index) / CGFloat(stepCount)
            let point = CGPoint(
                x: current.x + (target.x - current.x) * progress,
                y: current.y + (target.y - current.y) * progress
            )
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw StorybirdMCPError.pointerEventFailed
            }
            event.post(tap: .cghidEventTap)
            if durationMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Stops the stream once, then returns only a fully finalized MP4 result.
    func stop() async throws -> StorybirdMCPVideoRecording {
        let (shouldStop, stream, streamFailure) = stopLock.withLock {
            let shouldStop = !hasStopped
            hasStopped = true
            let stream = self.stream
            self.stream = nil
            return (shouldStop, stream, self.streamFailure)
        }

        if streamFailure != nil {
            frames.clear()
            videoWriter.cancel()
            throw StorybirdMCPError.recordingFailed
        }
        if shouldStop, let stream {
            try await stream.stopCaptureAsync()
        } else if !shouldStop {
            throw StorybirdMCPError.sessionNotActive
        }
        frames.clear()
        let result = try await videoWriter.finish()
        return StorybirdMCPVideoRecording(
            duration: result.duration,
            width: result.width,
            height: result.height
        )
    }

    /// Abandons a session without publishing or retaining its incomplete MP4.
    func abort() async {
        let stream = stopLock.withLock {
            hasStopped = true
            let stream = self.stream
            self.stream = nil
            return stream
        }
        if let stream {
            try? await stream.stopCaptureAsync()
        }
        frames.clear()
        videoWriter.cancel()
    }

    /// Marks an unexpected capture stop so later pointer commands cannot use stale pixels.
    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        stopLock.withLock {
            streamFailure = error
        }
    }

    /// Converts ScreenCaptureKit sample buffers into immutable CGImages.
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
        videoWriter.append(sampleBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(
            ciImage,
            from: ciImage.extent
        ) else {
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let captureFrame = (
            attachments?.first?[.screenRect] as? NSValue
        )?.rectValue ?? .zero
        frames.update(image, captureFrame: captureFrame)
    }

    /// Resolves a normalized point against the source's current Quartz frame.
    private func screenPoint(x: Double, y: Double) throws -> CGPoint {
        let isCaptureActive = stopLock.withLock {
            !hasStopped && streamFailure == nil && stream != nil
        }
        guard isCaptureActive else {
            throw StorybirdMCPError.recordingFailed
        }
        guard CGPreflightPostEventAccess() else {
            throw StorybirdMCPError.pointerControlPermission
        }
        guard frames.snapshot() != nil else {
            throw StorybirdMCPError.noFrame
        }
        let frame = currentCaptureFrame()
        guard frame.width > 0, frame.height > 0 else {
            throw StorybirdMCPError.sourceNotFound
        }
        return try StorybirdPointerGeometry.screenPoint(
            x: x,
            y: y,
            frame: frame
        )
    }

    /// Uses a moving window's live frame when the runtime exposes one.
    private func currentCaptureFrame() -> CGRect {
        var liveFrame = windowID.flatMap {
            CaptureFrameGeometry.currentWindowFrame(windowID: $0)
        }
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
        let fallback = initialCaptureFrame.width > 0
            && initialCaptureFrame.height > 0
            ? initialCaptureFrame
            : filter.contentRect
        return CaptureFrameGeometry.preferredFrame(
            sampleFrame: frames.snapshot()?.captureFrame,
            liveWindowFrame: liveFrame,
            fallbackFrame: fallback
        )
    }

    /// Waits for a new frame sequence so actions never return a pre-action image.
    private func waitForFrame(
        after sequence: UInt64?,
        timeoutMilliseconds: Int
    ) async throws -> StorybirdMCPFrame {
        let attempts = max(timeoutMilliseconds / 25, 1)
        for _ in 0..<attempts {
            if let snapshot = frames.snapshot(),
               sequence == nil || snapshot.sequence > sequence! {
                return try Self.frame(from: snapshot)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw StorybirdMCPError.noFrame
    }

    /// Encodes one locked snapshot without retaining mutable capture state.
    private static func frame(
        from snapshot: (
            image: CGImage,
            captureFrame: CGRect,
            sequence: UInt64
        )
    ) throws -> StorybirdMCPFrame {
        let bitmap = NSBitmapImageRep(cgImage: snapshot.image)
        guard let data = bitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw StorybirdMCPError.noFrame
        }
        return StorybirdMCPFrame(
            pngData: data,
            width: snapshot.image.width,
            height: snapshot.image.height
        )
    }

    /// Bounds large MCP wheel values before converting them to CoreGraphics units.
    private static func clampedInt32(_ value: Double) -> Int32 {
        let bounded = min(
            max(value.rounded(), Double(Int32.min)),
            Double(Int32.max)
        )
        return Int32(bounded)
    }
}

private extension SCStream {
    /// Bridges ScreenCaptureKit's start callback into structured concurrency.
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

    /// Bridges ScreenCaptureKit's stop callback so MP4 finalization waits.
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
