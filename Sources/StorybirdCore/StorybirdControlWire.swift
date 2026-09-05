import Darwin
import Foundation

public struct StorybirdControlRequest: Codable, Sendable {
    public let name: String
    public let argumentsJSON: Data

    public init(name: String, argumentsJSON: Data) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct StorybirdControlResponse: Codable, Sendable {
    public let text: String
    public let imageData: Data?
    public let isError: Bool

    public init(text: String, imageData: Data? = nil, isError: Bool = false) {
        self.text = text
        self.imageData = imageData
        self.isError = isError
    }
}

public enum StorybirdControlWireError: LocalizedError {
    case connectionClosed
    case oversizedMessage
    case invalidMessage
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "The Storybird control connection closed."
        case .oversizedMessage:
            return "The Storybird control message is too large."
        case .invalidMessage:
            return "The Storybird control message is invalid."
        case let .system(code):
            return String(cString: strerror(code))
        }
    }
}

public enum StorybirdControlWire {
    public static let maximumMessageBytes = 32 * 1024 * 1024

    /// Sends one length-prefixed Codable message over a local stream socket.
    public static func send<T: Encodable>(_ value: T, fileDescriptor: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumMessageBytes else {
            throw StorybirdControlWireError.oversizedMessage
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) {
            try writeAll($0, fileDescriptor: fileDescriptor)
        }
        try payload.withUnsafeBytes {
            try writeAll($0, fileDescriptor: fileDescriptor)
        }
    }

    /// Receives one complete length-prefixed Codable message.
    public static func receive<T: Decodable>(
        _ type: T.Type,
        fileDescriptor: Int32
    ) throws -> T {
        var length = UInt32.zero
        try withUnsafeMutableBytes(of: &length) {
            try readAll($0, fileDescriptor: fileDescriptor)
        }
        let count = Int(UInt32(bigEndian: length))
        guard count <= maximumMessageBytes else {
            throw StorybirdControlWireError.oversizedMessage
        }
        var payload = Data(count: count)
        try payload.withUnsafeMutableBytes {
            try readAll($0, fileDescriptor: fileDescriptor)
        }
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw StorybirdControlWireError.invalidMessage
        }
    }

    /// Writes every byte even when the local socket accepts a partial buffer.
    private static func writeAll(
        _ buffer: UnsafeRawBufferPointer,
        fileDescriptor: Int32
    ) throws {
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                fileDescriptor,
                buffer.baseAddress!.advanced(by: offset),
                buffer.count - offset
            )
            guard written > 0 else {
                throw StorybirdControlWireError.system(errno)
            }
            offset += written
        }
    }

    /// Reads exactly the requested byte count or reports a closed connection.
    private static func readAll(
        _ buffer: UnsafeMutableRawBufferPointer,
        fileDescriptor: Int32
    ) throws {
        var offset = 0
        while offset < buffer.count {
            let readCount = Darwin.read(
                fileDescriptor,
                buffer.baseAddress!.advanced(by: offset),
                buffer.count - offset
            )
            if readCount == 0 {
                throw StorybirdControlWireError.connectionClosed
            }
            guard readCount > 0 else {
                throw StorybirdControlWireError.system(errno)
            }
            offset += readCount
        }
    }
}
