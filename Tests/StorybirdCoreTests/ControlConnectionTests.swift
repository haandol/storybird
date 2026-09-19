import Darwin
import Foundation
import StorybirdCore
import XCTest

@MainActor
final class ControlConnectionTests: XCTestCase {
    func test_fragmentedHeaderAndBody_decodesOneCompleteMessage() async throws {
        let (local, peer) = try sockets()
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close(); Darwin.close(peer) }
        let request = StorybirdControlRequest(name: "fragmented", argumentsJSON: Data("{}".utf8))
        let payload = try JSONEncoder().encode(request)
        var length = UInt32(payload.count).bigEndian
        let message = withUnsafeBytes(of: &length) { Data($0) } + payload
        let writer = Task.detached {
            for byte in message {
                var value = byte
                _ = Darwin.write(peer, &value, 1)
                usleep(100)
            }
        }
        let result = try await connection.receive(StorybirdControlRequest.self)
        await writer.value
        XCTAssertEqual(result.name, request.name)
        XCTAssertEqual(result.argumentsJSON, request.argumentsJSON)
    }

    func test_disconnectedPeer_sendFailsWithoutSIGPIPE() async throws {
        let (local, peer) = try sockets()
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close() }
        Darwin.close(peer)
        do {
            try await connection.send(StorybirdControlResponse(text: "late response"))
            XCTFail("A closed peer must fail")
        } catch {}
    }

    func test_cancelledRead_finishesAndClosesConnection() async throws {
        let (local, peer) = try sockets()
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close(); Darwin.close(peer) }
        let finished = expectation(description: "Cancelled read finishes")
        let reader = Task {
            do {
                _ = try await connection.receive(StorybirdControlResponse.self)
                XCTFail("Cancelled read must not succeed")
            } catch {}
            finished.fulfill()
        }
        reader.cancel()
        await fulfillment(of: [finished], timeout: 2)
    }

    func test_cancelledBlockedWrite_finishesWithoutBlockingExecutor() async throws {
        let (local, peer) = try sockets()
        var size: Int32 = 1_024
        _ = setsockopt(local, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close(); Darwin.close(peer) }
        let finished = expectation(description: "Cancelled write finishes")
        let writer = Task {
            do {
                try await connection.send(StorybirdControlResponse(text: String(repeating: "x", count: 1_000_000)))
                XCTFail("Unread large response must not finish")
            } catch {}
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(50))
        writer.cancel()
        await fulfillment(of: [finished], timeout: 2)
    }

    func test_oversizedHeader_rejectsWithoutReadingBodyAndCanReturnError() async throws {
        let (local, peer) = try sockets()
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close(); Darwin.close(peer) }
        var length = UInt32(StorybirdControlWire.maximumMessageBytes + 1).bigEndian
        _ = withUnsafeBytes(of: &length) { Darwin.write(peer, $0.baseAddress, $0.count) }
        do {
            _ = try await connection.receive(StorybirdControlRequest.self)
            XCTFail("Oversized frame must fail")
        } catch StorybirdControlWireError.oversizedMessage {
            try await connection.send(StorybirdControlResponse(text: "oversized", isError: true))
            let result = try StorybirdControlWire.receive(StorybirdControlResponse.self, fileDescriptor: peer)
            XCTAssertTrue(result.isError)
        }
    }

    func test_peerClosesPartialBody_readReportsFailure() async throws {
        let (local, peer) = try sockets()
        let connection = try StorybirdControlConnection(fileDescriptor: local)
        defer { connection.close() }
        var length = UInt32(100).bigEndian
        _ = withUnsafeBytes(of: &length) { Darwin.write(peer, $0.baseAddress, $0.count) }
        Darwin.close(peer)
        do {
            _ = try await connection.receive(StorybirdControlRequest.self)
            XCTFail("Incomplete body must fail")
        } catch StorybirdControlWireError.connectionClosed {}
    }

    private func sockets() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw StorybirdControlWireError.system(errno)
        }
        return (descriptors[0], descriptors[1])
    }
}
