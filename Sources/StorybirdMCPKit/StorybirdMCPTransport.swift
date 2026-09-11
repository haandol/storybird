import Foundation
import Logging
import MCP

/// Adapts capability metadata that the pinned SDK cannot decode.
actor StorybirdMCPTransport: Transport {
    nonisolated let logger: Logger
    private let underlying: any Transport

    init(_ underlying: any Transport) async {
        self.underlying = underlying
        logger = await underlying.logger
    }

    func connect() async throws {
        try await underlying.connect()
    }

    func disconnect() async {
        await underlying.disconnect()
    }

    func send(_ data: Data) async throws {
        try await underlying.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messages = await underlying.receive()
                    for try await message in messages {
                        try Task.checkCancellation()
                        continuation.yield(Self.compatibleInitialization(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// MCP permits arbitrary experimental capability values, but Swift SDK 0.12.1
    /// decodes them as [String: String]. Storybird negotiates no experimental
    /// features, so ignore unsupported values only in initialize metadata.
    /// Leave all other fields and malformed messages to the SDK's validation.
    static func compatibleInitialization(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["method"] as? String == Initialize.name,
              var parameters = request["params"] as? [String: Any],
              var capabilities = parameters["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              experimental.values.contains(where: { !($0 is String) })
        else { return data }

        capabilities["experimental"] = experimental.filter { $0.value is String }
        parameters["capabilities"] = capabilities
        request["params"] = parameters
        return (try? JSONSerialization.data(withJSONObject: request)) ?? data
    }
}
