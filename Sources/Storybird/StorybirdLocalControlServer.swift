import Darwin
import Foundation
import Security
import StorybirdCore

actor StorybirdOrderedRequestGate {
    private var nextSequence: UInt64 = 0
    private var waiters: [
        UInt64: CheckedContinuation<Void, Never>
    ] = [:]

    /// Waits until every earlier accepted pointer-lifecycle request has completed.
    func wait(for sequence: UInt64) async {
        guard sequence != nextSequence else { return }
        await withCheckedContinuation { continuation in
            waiters[sequence] = continuation
        }
    }

    /// Advances the admission boundary and releases exactly the next accepted request.
    func complete(_ sequence: UInt64) {
        guard sequence == nextSequence else { return }
        nextSequence &+= 1
        waiters.removeValue(forKey: nextSequence)?.resume()
    }
}

final class StorybirdLocalControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (
        StorybirdControlRequest
    ) async -> StorybirdControlResponse

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(
        label: "io.storybird.local-control",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let orderedRequests = StorybirdOrderedRequestGate()
    private var listener: Int32 = -1

    init(rootURL: URL, handler: @escaping Handler) {
        socketPath = rootURL.appendingPathComponent("control.sock").path
        self.handler = handler
    }

    /// Starts the user-only local listener without opening a TCP port.
    func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw StorybirdControlWireError.system(errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                _ = strlcpy(
                    UnsafeMutableRawPointer(pointer)
                        .assumingMemoryBound(to: CChar.self),
                    source,
                    pathCapacity
                )
            }
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw StorybirdControlWireError.system(code)
        }
        chmod(socketPath, S_IRUSR | S_IWUSR)
        lock.withLock { listener = fd }
        queue.async { [weak self] in self?.acceptLoop(fd: fd) }
    }

    /// Stops accepting commands and removes the socket path.
    func stop() {
        let fd = lock.withLock {
            let fd = listener
            listener = -1
            return fd
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
        unlink(socketPath)
    }

    /// Accepts one request per authenticated companion connection.
    private func acceptLoop(fd: Int32) {
        var nextOrderedSequence: UInt64 = 0
        while lock.withLock({ listener == fd }) {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { continue }
            guard Self.isAuthorizedPeer(client) else {
                try? StorybirdControlWire.send(
                    StorybirdControlResponse(
                        text: "Storybird rejected the unsigned or untrusted MCP companion.",
                        isError: true
                    ),
                    fileDescriptor: client
                )
                Darwin.close(client)
                continue
            }
            let request: StorybirdControlRequest
            do {
                request = try StorybirdControlWire.receive(
                    StorybirdControlRequest.self,
                    fileDescriptor: client
                )
            } catch {
                try? StorybirdControlWire.send(
                    StorybirdControlResponse(
                        text: error.localizedDescription,
                        isError: true
                    ),
                    fileDescriptor: client
                )
                Darwin.close(client)
                continue
            }
            let orderedSequence: UInt64? =
                Self.requiresOrderedHandling(request.name)
                ? nextOrderedSequence
                : nil
            if orderedSequence != nil {
                nextOrderedSequence &+= 1
            }
            Task { [handler, orderedRequests] in
                if let orderedSequence {
                    await orderedRequests.wait(for: orderedSequence)
                }
                let response = await handler(request)
                try? StorybirdControlWire.send(
                    response,
                    fileDescriptor: client
                )
                Darwin.close(client)
                if let orderedSequence {
                    await orderedRequests.complete(orderedSequence)
                }
            }
        }
    }

    /// Orders only commands whose real input or recording lifecycle must follow acceptance order.
    private static func requiresOrderedHandling(_ name: String) -> Bool {
        switch name {
        case "storybird_start_session",
             "storybird_move_pointer",
             "storybird_click",
             "storybird_scroll",
             "storybird_stop_session":
            return true
        default:
            return false
        }
    }

    /// Allows only a strictly valid StorybirdMCP signature from the app's Team ID.
    private static func isAuthorizedPeer(_ fd: Int32) -> Bool {
        var peerPID = pid_t.zero
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            fd,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &length
        ) == 0,
            let appInfo = signingInfo(forPID: getpid()),
            let peerInfo = signingInfo(forPID: peerPID),
            appInfo.teamID != nil,
            appInfo.teamID == peerInfo.teamID,
            peerInfo.identifier == "StorybirdMCP"
        else {
            return false
        }
        return true
    }

    /// Validates on-disk code before reading the identifier and Team ID for a peer process.
    private static func signingInfo(
        forPID pid: pid_t
    ) -> (identifier: String?, teamID: String?)? {
        var pathBuffer = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let pathLength = proc_pidpath(
            pid,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else {
            return nil
        }
        let path = pathBuffer.withUnsafeBytes {
            String(
                decoding: $0.prefix(Int(pathLength)),
                as: UTF8.self
            )
        }
        let codeURL = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            codeURL,
            [],
            &staticCode
        ) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate
                        | kSecCSCheckAllArchitectures
                ),
                nil
            ) == errSecSuccess
        else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [CFString: Any]
        else {
            return nil
        }
        return (
            values[kSecCodeInfoIdentifier] as? String,
            values[kSecCodeInfoTeamIdentifier] as? String
        )
    }

    deinit {
        stop()
    }
}
