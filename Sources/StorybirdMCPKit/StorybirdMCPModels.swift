import Foundation

public enum StorybirdMCPSourceKind: String, Codable, Sendable {
    case display
    case window
}

public struct StorybirdMCPSourceDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let kind: StorybirdMCPSourceKind
    public let title: String
    public let subtitle: String
    public let width: Double
    public let height: Double

    public init(
        id: String,
        kind: StorybirdMCPSourceKind,
        title: String,
        subtitle: String,
        width: Double,
        height: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
    }
}

public struct StorybirdMCPFrame: Hashable, Sendable {
    public let pngData: Data
    public let width: Int
    public let height: Int

    public init(
        pngData: Data,
        width: Int,
        height: Int
    ) {
        self.pngData = pngData
        self.width = width
        self.height = height
    }
}

public enum StorybirdMCPPointerButton: String, Codable, Sendable {
    case left
    case right
}

public struct StorybirdMCPVideoRecording: Hashable, Sendable {
    public let duration: Double
    public let width: Int
    public let height: Int

    public init(duration: Double, width: Int, height: Int) {
        self.duration = duration
        self.width = width
        self.height = height
    }
}

public struct StorybirdMCPClickResult: Hashable, Sendable {
    public let frame: StorybirdMCPFrame
    public let recordingTime: Double
    public let observedFreshFrame: Bool

    public init(
        frame: StorybirdMCPFrame,
        recordingTime: Double,
        observedFreshFrame: Bool
    ) {
        self.frame = frame
        self.recordingTime = recordingTime
        self.observedFreshFrame = observedFreshFrame
    }
}

public enum StorybirdMCPError: LocalizedError, Sendable {
    case sessionAlreadyActive
    case sessionNotActive
    case sessionStopping
    case consentRequired
    case sourceNotFound
    case invalidProjectName
    case invalidOutputPath
    case invalidCoordinate
    case invalidScroll
    case noFrame
    case screenRecordingPermission
    case pointerControlPermission
    case pointerEventFailed
    case recordingFailed

    public var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "A Storybird MCP session is already active."
        case .sessionNotActive:
            return "Start a Storybird MCP session first."
        case .sessionStopping:
            return "The Storybird MCP session is stopping."
        case .consentRequired:
            return "Starting a session requires explicit approval to share the selected screen and control the pointer."
        case .sourceNotFound:
            return "The selected capture source is no longer available."
        case .invalidProjectName:
            return "The Storybird project name cannot be empty."
        case .invalidOutputPath:
            return "The output path must end in .mp4."
        case .invalidCoordinate:
            return "Pointer coordinates must be finite values from 0 through 1."
        case .invalidScroll:
            return "Scroll deltas must be finite values."
        case .noFrame:
            return "No valid frame is available for the selected source."
        case .screenRecordingPermission:
            return "Screen Recording permission is required for Storybird MCP."
        case .pointerControlPermission:
            return "Accessibility permission to control the pointer is required for Storybird MCP."
        case .pointerEventFailed:
            return "macOS could not create the requested pointer event."
        case .recordingFailed:
            return "The Storybird video recording could not be finalized."
        }
    }
}

public protocol StorybirdDesktopPlatform: Sendable {
    /// Lists only display and ordinary window sources that can define one session.
    func listSources() async throws -> [StorybirdMCPSourceDescriptor]

    /// Starts one isolated capture source after screen and pointer permissions pass.
    func startSession(
        sourceID: String,
        recordingURL: URL
    ) async throws -> any StorybirdDesktopSession
}

public protocol StorybirdDesktopSession: Sendable {
    /// Returns the immutable source identity selected when the session began.
    func sourceDescriptor() async -> StorybirdMCPSourceDescriptor

    /// Returns the latest valid PNG without changing the target application.
    func latestFrame() async throws -> StorybirdMCPFrame

    /// Moves the visible macOS pointer within the selected source.
    func movePointer(
        x: Double,
        y: Double,
        durationMilliseconds: Int
    ) async throws -> StorybirdMCPFrame

    /// Posts one visible mouse click and waits for a resulting capture frame.
    func click(
        x: Double,
        y: Double,
        button: StorybirdMCPPointerButton
    ) async throws -> StorybirdMCPClickResult

    /// Posts a wheel event at a normalized point and returns the resulting frame.
    func scroll(
        x: Double,
        y: Double,
        deltaX: Double,
        deltaY: Double
    ) async throws -> StorybirdMCPFrame

    /// Stops capture and finalizes the session-owned MP4 before project persistence.
    func stop() async throws -> StorybirdMCPVideoRecording

    /// Cancels capture and removes an incomplete session-owned MP4.
    func abort() async
}
