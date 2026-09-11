import Foundation
import MCP
import XCTest
@testable import StorybirdMCPKit

final class MCPInitializationTests: XCTestCase {
    func test_objectExperimentalCapabilities_initializesAndListsToolsWithoutAppAccess() async throws {
        let ipc = StorybirdAppIPCClient(
            sender: { _ in XCTFail("Initialization must not access the app"); throw FixtureError.unexpectedIPC },
            launcher: { XCTFail("Initialization must not launch the app"); throw FixtureError.unexpectedIPC }
        )
        let pair = await InMemoryTransport.createConnectedPair()
        let server = try await StorybirdMCPService(client: ipc).startServer(transport: pair.server)
        try await pair.client.connect()
        // Bound the receive even when a broken server never responds.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            await pair.client.disconnect()
        }
        do {
            var responses = await pair.client.receive().makeAsyncIterator()
            try await pair.client.send(Data(#"""
            {"jsonrpc":"2.0","id":"invalid","method":"initialize","params":{"capabilities":{"experimental":{"example":{}},"roots":{"listChanged":"invalid"}}}}
            """#.utf8))
            let malformedInitialization = try await responses.next()
            XCTAssertNotNil(try decode(XCTUnwrap(malformedInitialization))["error"],
                            "Compatibility must preserve validation of standard capabilities.")
            try await pair.client.send(Data(#"""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"external-client","version":"1"},"capabilities":{"experimental":{"example/app":{"nested":[true,1,null]}},"roots":{"listChanged":true}}}}
            """#.utf8))
            let initialization = try await responses.next()
            let response = try decode(XCTUnwrap(initialization))
            XCTAssertNil(response["error"])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
            let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
            XCTAssertNotNil(capabilities["tools"])
            XCTAssertNil(capabilities["experimental"])

            try await pair.client.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8))
            let discovery = try await responses.next()
            let toolsResponse = try decode(XCTUnwrap(discovery))
            let toolsResult = try XCTUnwrap(toolsResponse["result"] as? [String: Any])
            let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
            XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                           Set(StorybirdMCPService.toolDefinitions.map(\.name)))
            try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#.utf8))
            let repeatedInitialization = try await responses.next()
            XCTAssertNotNil(try decode(XCTUnwrap(repeatedInitialization))["error"],
                            "Compatibility must preserve the strict initialized state.")
            deadline.cancel()
            await pair.client.disconnect()
            await server.stop()
        } catch {
            deadline.cancel()
            await pair.client.disconnect()
            await server.stop()
            throw error
        }
    }

    func test_initializationAdapter_preservesUnrelatedFieldsAndStringCapabilities() throws {
        let input = Data(#"""
        {"jsonrpc":"2.0","id":"request-1","method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"fixture","version":"1"},"capabilities":{"experimental":{"object":{},"array":[],"bool":true,"number":1,"null":null,"string":"kept"},"roots":{"listChanged":true}},"_meta":{"key":"value"}}}
        """#.utf8)
        var expected = try decode(input)
        var parameters = try XCTUnwrap(expected["params"] as? [String: Any])
        var capabilities = try XCTUnwrap(parameters["capabilities"] as? [String: Any])
        capabilities["experimental"] = ["string": "kept"]
        parameters["capabilities"] = capabilities
        expected["params"] = parameters
        let actual = try decode(StorybirdMCPTransport.compatibleInitialization(input))
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary)
    }

    func test_unrelatedOrMalformedMessages_remainByteIdentical() {
        for message in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
            #"{"method":"initialize","params":{"capabilities":{"experimental":{"legacy":"ok"}}}}"#,
            #"{"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
            #"{"method":"initialize","params":{"capabilities":{"experimental":false}}}"#,
            #"{"method":"tools/call","params":{"capabilities":{"experimental":{"x":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"experimental":{"x":{}}}}}"#,
            #"{"method":"initialize","params":"invalid"}"#,
            "invalid JSON",
        ] {
            let data = Data(message.utf8)
            XCTAssertEqual(StorybirdMCPTransport.compatibleInitialization(data), data)
        }
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum FixtureError: Error { case unexpectedIPC }
