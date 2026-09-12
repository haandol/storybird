import AppKit
import Darwin
import Foundation
import StorybirdCore

enum StorybirdAppIPCStageError: LocalizedError, Sendable {
    case connectionUnavailable(String)
    case resultUnknown(String)

    var errorDescription: String? {
        switch self {
        case let .connectionUnavailable(message):
            return "Storybird is unavailable: \(message)"
        case let .resultUnknown(message):
            return "Storybird may have executed the command, but its response was lost: \(message)"
        }
    }
}

public struct StorybirdAppIPCClient: Sendable {
    private let sender: @Sendable (
        StorybirdControlRequest
    ) async throws -> StorybirdControlResponse
    private let launcher: @Sendable () async throws -> Void

    public init() {
        sender = Self.send
        launcher = Self.launchStorybird
    }

    init(
        sender: @escaping @Sendable (
            StorybirdControlRequest
        ) async throws -> StorybirdControlResponse,
        launcher: @escaping @Sendable () async throws -> Void
    ) {
        self.sender = sender
        self.launcher = launcher
    }

    /// Retries only before a request is sent so real pointer commands are never replayed ambiguously.
    public func call(
        name: String,
        argumentsJSON: Data,
        launchIfNeeded: Bool = true
    ) async throws -> StorybirdControlResponse {
        let request = StorybirdControlRequest(
            name: name,
            argumentsJSON: argumentsJSON
        )
        do {
            return try await sender(request)
        } catch let error as StorybirdAppIPCStageError {
            guard case .connectionUnavailable = error else {
                throw error
            }
            guard launchIfNeeded else {
                throw error
            }
            try await launcher()
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(100))
                do {
                    let response = try await sender(request)
                    return response
                } catch let retryError as StorybirdAppIPCStageError {
                    guard case .connectionUnavailable = retryError else {
                        throw retryError
                    }
                } catch {
                    throw error
                }
            }
            throw error
        }
    }

    /// Performs blocking Unix-socket I/O away from the cooperative executor.
    private static func send(
        _ request: StorybirdControlRequest
    ) async throws -> StorybirdControlResponse {
        try await Task.detached {
            let fd: Int32
            do {
                fd = try Self.connectSocket()
            } catch {
                throw StorybirdAppIPCStageError.connectionUnavailable(
                    error.localizedDescription
                )
            }
            defer { Darwin.close(fd) }
            do {
                try StorybirdControlWire.send(
                    request,
                    fileDescriptor: fd
                )
                return try StorybirdControlWire.receive(
                    StorybirdControlResponse.self,
                    fileDescriptor: fd
                )
            } catch {
                throw StorybirdAppIPCStageError.resultUnknown(
                    error.localizedDescription
                )
            }
        }.value
    }

    /// Launches the enclosing Storybird app without requesting capture permissions.
    private static func launchStorybird() async throws {
        let executableURL = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).standardizedFileURL
        let appURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        await MainActor.run {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: .init()
            )
        }
    }

    /// Connects to Storybird's user-only Unix socket.
    private static func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw StorybirdControlWireError.system(errno)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = try socketPath()
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
            else {
                throw StorybirdControlWireError.invalidMessage
            }
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                path.withCString { source in
                    _ = strlcpy(
                        UnsafeMutableRawPointer(pointer)
                            .assumingMemoryBound(to: CChar.self),
                        source,
                        pathCapacity
                    )
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        fd,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else {
                throw StorybirdControlWireError.system(errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Resolves the same per-user path used by Storybird's library root.
    private static func socketPath() throws -> String {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StorybirdControlWireError.invalidMessage
        }
        return applicationSupport
            .appendingPathComponent("Storybird", isDirectory: true)
            .appendingPathComponent("control.sock")
            .path
    }
}
