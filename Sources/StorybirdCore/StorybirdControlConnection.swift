import Darwin
import Foundation

/// Owns one request/response socket. Readiness callbacks never block a Swift
/// executor or the app's listener while a peer is paused or has disconnected.
public final class StorybirdControlConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "io.storybird.control-connection")
    // All mutable state below belongs to queue.
    private var closed = false
    private var descriptorClosed = false
    private var sourceCount = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var input = Data()
    private var inputLength: Int?
    private var output = Data()
    private var outputOffset = 0

    /// Transfers ownership of the socket, including when configuration fails.
    public init(fileDescriptor: Int32) throws {
        descriptor = fileDescriptor
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            descriptorClosed = true
            throw StorybirdControlWireError.system(code)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            descriptorClosed = true
            throw StorybirdControlWireError.system(code)
        }
    }

    public func receive<Value: Decodable & Sendable>(_ type: Value.Type) async throws -> Value {
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else {
                        continuation.resume(throwing: StorybirdControlWireError.connectionClosed)
                        return
                    }
                    guard self.readContinuation == nil else {
                        continuation.resume(throwing: StorybirdControlWireError.invalidMessage)
                        return
                    }
                    self.input = Data()
                    self.inputLength = nil
                    self.readContinuation = continuation
                    let source = DispatchSource.makeReadSource(fileDescriptor: self.descriptor, queue: self.queue)
                    self.readSource = source
                    self.sourceCount += 1
                    source.setEventHandler { self.readAvailable() }
                    source.setCancelHandler { self.sourceCancelled() }
                    source.resume()
                }
            }
        } onCancel: {
            self.close()
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StorybirdControlWireError.invalidMessage
        }
    }

    public func send<Value: Encodable & Sendable>(_ value: Value) async throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= StorybirdControlWire.maximumMessageBytes else {
            throw StorybirdControlWireError.oversizedMessage
        }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        let message = header + payload
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !self.closed else {
                        continuation.resume(throwing: StorybirdControlWireError.connectionClosed)
                        return
                    }
                    guard self.writeContinuation == nil else {
                        continuation.resume(throwing: StorybirdControlWireError.invalidMessage)
                        return
                    }
                    self.output = message
                    self.outputOffset = 0
                    self.writeContinuation = continuation
                    let source = DispatchSource.makeWriteSource(fileDescriptor: self.descriptor, queue: self.queue)
                    self.writeSource = source
                    self.sourceCount += 1
                    source.setEventHandler { self.writeAvailable() }
                    source.setCancelHandler { self.sourceCancelled() }
                    source.resume()
                }
            }
        } onCancel: {
            self.close()
        }
    }

    /// Shutdown wakes the peer; close waits for every readiness source to retire
    /// so a queued callback cannot access a reused file descriptor.
    public func close() {
        queue.async { self.fail(StorybirdControlWireError.connectionClosed) }
    }

    private func readAvailable() {
        guard !closed, readContinuation != nil else { return }
        while true {
            let target = inputLength.map { 4 + $0 } ?? 4
            let remaining = target - input.count
            if remaining == 0 {
                if inputLength == nil {
                    let length = input.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                    guard length <= StorybirdControlWire.maximumMessageBytes else {
                        let continuation = readContinuation
                        readContinuation = nil
                        input = Data()
                        readSource?.cancel()
                        readSource = nil
                        continuation?.resume(throwing: StorybirdControlWireError.oversizedMessage)
                        return
                    }
                    inputLength = Int(length)
                    continue
                }
                let continuation = readContinuation
                readContinuation = nil
                readSource?.cancel()
                readSource = nil
                let payload = Data(input.dropFirst(4))
                input = Data()
                continuation?.resume(returning: payload)
                return
            }
            var buffer = [UInt8](repeating: 0, count: min(remaining, 65_536))
            let count = Darwin.recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if count > 0 {
                input.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                fail(StorybirdControlWireError.connectionClosed)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                fail(StorybirdControlWireError.system(errno))
                return
            }
        }
    }

    private func writeAvailable() {
        guard !closed, writeContinuation != nil else { return }
        while outputOffset < output.count {
            let count = output.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: outputOffset),
                            output.count - outputOffset, MSG_DONTWAIT)
            }
            if count > 0 {
                outputOffset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                fail(StorybirdControlWireError.system(count == 0 ? EPIPE : errno))
                return
            }
        }
        let continuation = writeContinuation
        writeContinuation = nil
        output = Data()
        writeSource?.cancel()
        writeSource = nil
        continuation?.resume()
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
        let read = readContinuation
        let write = writeContinuation
        readContinuation = nil
        writeContinuation = nil
        input = Data()
        output = Data()
        read?.resume(throwing: error)
        write?.resume(throwing: error)
        closeDescriptorIfReady()
    }

    private func sourceCancelled() {
        sourceCount -= 1
        closeDescriptorIfReady()
    }

    private func closeDescriptorIfReady() {
        if closed && sourceCount == 0 && !descriptorClosed {
            descriptorClosed = true
            Darwin.close(descriptor)
        }
    }

    deinit {
        // No source can still own self here.
        if !descriptorClosed { Darwin.close(descriptor) }
    }
}
