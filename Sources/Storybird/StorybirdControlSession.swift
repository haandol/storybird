import Foundation
import StorybirdCore
import StorybirdMCPKit

actor StorybirdSerialActionQueue {
    private var isAccepting = false
    private var tail = Task<Void, Never> {}

    /// Opens a fresh queue after any previous session has drained.
    func open() {
        isAccepting = true
        tail = Task {}
    }

    /// Runs accepted pointer commands in arrival order even when clients call concurrently.
    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard isAccepting else {
            throw StorybirdMCPError.sessionStopping
        }
        let previous = tail
        let task = Task<T, Error> {
            await previous.value
            return try await operation()
        }
        tail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }

    /// Rejects new commands and waits for every previously accepted command.
    func closeAndDrain() async {
        isAccepting = false
        let pending = tail
        await pending.value
    }
}

actor StorybirdControlSession {
    struct CompletedRecording: Sendable {
        let projectID: UUID
        let projectName: String
        let filename: String
        let result: ScreenVideoRecordingResult
        let clicks: [TimedPointerClick]
    }

    private struct ActiveSession {
        let id: UUID
        let source: StorybirdMCPSourceDescriptor
        let desktop: any StorybirdDesktopSession
        let projectID: UUID
        let projectName: String
        let filename: String
        let outputURL: URL
        var clicks: [TimedPointerClick]
    }

    private enum State {
        case idle
        case active(ActiveSession)
        case stopping
    }

    private let platform: any StorybirdDesktopPlatform
    private let actions = StorybirdSerialActionQueue()
    private var state: State = .idle

    public init() {
        platform = ScreenCaptureDesktopPlatform()
    }

    init(platform: any StorybirdDesktopPlatform) {
        self.platform = platform
    }

    /// Lists current sources without starting capture or posting any input.
    public func listSources() async throws -> [StorybirdMCPSourceDescriptor] {
        try await platform.listSources()
    }

    /// Starts one consented source session and returns its first observable frame.
    public func startSession(
        sourceID: String,
        projectID: UUID,
        projectName: String,
        recordingFilename: String,
        outputURL: URL
    ) async throws -> StorybirdMCPFrame {
        guard case .idle = state else {
            throw StorybirdMCPError.sessionAlreadyActive
        }
        let trimmedName = projectName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty else {
            throw StorybirdMCPError.invalidProjectName
        }
        guard outputURL.pathExtension.lowercased() == "mp4" else {
            throw StorybirdMCPError.invalidOutputPath
        }

        let desktop = try await platform.startSession(
            sourceID: sourceID,
            recordingURL: outputURL
        )
        do {
            let source = await desktop.sourceDescriptor()
            let firstFrame = try await desktop.latestFrame()
            state = .active(
                ActiveSession(
                    id: UUID(),
                    source: source,
                    desktop: desktop,
                    projectID: projectID,
                    projectName: trimmedName,
                    filename: recordingFilename,
                    outputURL: outputURL,
                    clicks: []
                )
            )
            await actions.open()
            return firstFrame
        } catch {
            await desktop.abort()
            throw error
        }
    }

    /// Returns the selected source's current PNG only while a session is active.
    public func observe() async throws -> StorybirdMCPFrame {
        let active = try activeSession()
        return try await active.desktop.latestFrame()
    }

    /// Queues a visible pointer move so concurrent MCP calls cannot reorder actions.
    public func movePointer(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws -> StorybirdMCPFrame {
        try Self.validateCoordinate(x: x, y: y)
        let duration = min(max(durationMilliseconds, 0), 5_000)
        return try await actions.enqueue { [weak self] in
            guard let self else {
                throw StorybirdMCPError.sessionNotActive
            }
            return try await self.performMove(
                x: x,
                y: y,
                durationMilliseconds: duration
            )
        }
    }

    /// Queues one click and records its clicked and resulting frames exactly once.
    public func click(
        x: Double,
        y: Double,
        button: StorybirdMCPPointerButton
    ) async throws -> StorybirdMCPClickResult {
        try Self.validateCoordinate(x: x, y: y)
        return try await actions.enqueue { [weak self] in
            guard let self else {
                throw StorybirdMCPError.sessionNotActive
            }
            return try await self.performClick(
                x: x,
                y: y,
                button: button
            )
        }
    }

    /// Queues one wheel event while leaving keyboard input outside the session.
    public func scroll(
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) async throws -> StorybirdMCPFrame {
        try Self.validateCoordinate(x: x, y: y)
        guard deltaX.isFinite, deltaY.isFinite else {
            throw StorybirdMCPError.invalidScroll
        }
        return try await actions.enqueue { [weak self] in
            guard let self else {
                throw StorybirdMCPError.sessionNotActive
            }
            return try await self.performScroll(
                x: x,
                y: y,
                deltaX: deltaX,
                deltaY: deltaY
            )
        }
    }

    /// Drains pointer commands and returns one finalized video project payload.
    public func stopSession() async throws -> CompletedRecording {
        guard case .active = state else {
            throw StorybirdMCPError.sessionNotActive
        }
        await actions.closeAndDrain()

        guard case let .active(active) = state else {
            throw StorybirdMCPError.sessionNotActive
        }
        state = .stopping
        do {
            let recording = try await active.desktop.stop()
            let result = CompletedRecording(
                projectID: active.projectID,
                projectName: active.projectName,
                filename: active.filename,
                result: ScreenVideoRecordingResult(
                    duration: recording.duration,
                    width: recording.width,
                    height: recording.height
                ),
                clicks: active.clicks
            )
            state = .idle
            return result
        } catch {
            await active.desktop.abort()
            try? FileManager.default.removeItem(
                at: active.outputURL.deletingLastPathComponent()
            )
            state = .idle
            throw error
        }
    }

    /// Stops an abandoned capture when its MCP transport disconnects.
    public func abort() async {
        await actions.closeAndDrain()
        if case let .active(active) = state {
            await active.desktop.abort()
            try? FileManager.default.removeItem(
                at: active.outputURL.deletingLastPathComponent()
            )
        }
        state = .idle
    }

    /// Moves the pointer without adding a click layer to the recording timeline.
    private func performMove(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws -> StorybirdMCPFrame {
        let active = try activeSession()
        return try await active.desktop.movePointer(
            x: x,
            y: y,
            durationMilliseconds: durationMilliseconds
        )
    }

    /// Records one successful pointer action on the same zero-based clock as the MP4.
    private func performClick(
        x: Double,
        y: Double,
        button: StorybirdMCPPointerButton
    ) async throws -> StorybirdMCPClickResult {
        let active = try activeSession()
        let result = try await active.desktop.click(
            x: x,
            y: y,
            button: button
        )

        guard case var .active(current) = state,
              current.id == active.id
        else {
            throw StorybirdMCPError.sessionNotActive
        }
        current.clicks.append(
            TimedPointerClick(
                time: result.recordingTime,
                x: x,
                y: y,
                button: button == .left ? .left : .right
            )
        )
        state = .active(current)
        return result
    }

    /// Posts a scroll command while continuous capture preserves the visible motion.
    private func performScroll(
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) async throws -> StorybirdMCPFrame {
        let active = try activeSession()
        return try await active.desktop.scroll(
            x: x,
            y: y,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    /// Extracts the active state without exposing mutable session storage.
    private func activeSession() throws -> ActiveSession {
        guard case let .active(active) = state else {
            throw StorybirdMCPError.sessionNotActive
        }
        return active
    }

    /// Enforces the normalized pointer coordinate contract before any OS event.
    private static func validateCoordinate(x: Double, y: Double) throws {
        guard x.isFinite,
              y.isFinite,
              (0...1).contains(x),
              (0...1).contains(y)
        else {
            throw StorybirdMCPError.invalidCoordinate
        }
    }
}
