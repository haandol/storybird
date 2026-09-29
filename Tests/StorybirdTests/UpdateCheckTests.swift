import AppKit
import Foundation
import MCP
import StorybirdCore
import SwiftUI
import XCTest
@testable import Storybird
@testable import StorybirdMCPKit

@MainActor
final class UpdateCheckTests: XCTestCase {
    func test_settingsAndStartupAndStatusReads_doNotSendRequests() async throws {
        let (checker, session) = makeChecker()
        defer { session.invalidateAndCancel() }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: ProjectRepository(rootURL: root), updateChecker: checker)
        let view = NSHostingView(rootView: StorybirdUpdateSettingsView(checker: store.updateChecker))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 120)
        view.layoutSubtreeIfNeeded()
        for _ in 0..<10 { _ = checker.status; await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(checker.status.state, .idle)
        XCTAssertEqual(checker.status.currentVersion, "0.1.13")
        XCTAssertEqual(checker.status.buildNumber, "14")
        XCTAssertTrue(UpdateHTTPProtocol.fixture.requests.isEmpty)
    }

    func test_explicitCheck_comparesNewEqualAndOlderReleases() async throws {
        for (tag, expected) in [("v0.10.0", AppUpdateStatus.State.updateAvailable),
                                ("v0.1.13", .upToDate), ("0.1.12", .upToDate)] {
            let (checker, session) = makeChecker()
            defer { session.invalidateAndCancel() }
            UpdateHTTPProtocol.fixture.setReply(.release(tag))
            await checker.check()
            XCTAssertEqual(checker.status.state, expected)
            XCTAssertEqual(checker.status.latestVersion, AppVersion(tag, allowingTagPrefix: true)?.description)
            XCTAssertEqual(checker.status.releaseURL, "https://github.com/haandol/storybird/releases/tag/\(tag)")
            XCTAssertNil(checker.status.error)
            XCTAssertEqual(UpdateHTTPProtocol.fixture.requests.count, 1)
        }
    }

    func test_request_containsOnlyPublicMetadataAndTenSecondLimits() async throws {
        let (checker, session) = makeChecker()
        defer { session.invalidateAndCancel() }
        await checker.check()
        let request = try XCTUnwrap(UpdateHTTPProtocol.fixture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/haandol/storybird/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Storybird-Update-Check")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        let configuration = StorybirdUpdateChecker.sessionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func test_invalidCurrentVersion_failsWithoutNetwork() async {
        for version in [nil, "", "0.1", "v0.1.13"] as [String?] {
            let (checker, session) = makeChecker(version: version)
            defer { session.invalidateAndCancel() }
            await checker.check()
            XCTAssertEqual(checker.status.state, .failed)
            XCTAssertNotNil(checker.status.error)
            XCTAssertTrue(UpdateHTTPProtocol.fixture.requests.isEmpty)
        }
    }

    func test_networkHttpJsonAndVersionFailures_allowExplicitRetry() async {
        let failures = [UpdateHTTPReply(status: 403), UpdateHTTPReply(status: 404), UpdateHTTPReply(status: 302),
                        UpdateHTTPReply(status: 500), UpdateHTTPReply(body: "not json"),
                        UpdateHTTPReply(body: "{}"), .release("v0.2"),
                        UpdateHTTPReply(error: .notConnectedToInternet), UpdateHTTPReply(error: .timedOut)]
        for reply in failures {
            let (checker, session) = makeChecker()
            defer { session.invalidateAndCancel() }
            UpdateHTTPProtocol.fixture.setReply(reply)
            await checker.check()
            XCTAssertEqual(checker.status.state, .failed)
            XCTAssertNotNil(checker.status.error)
            XCTAssertNil(checker.status.latestVersion)
            XCTAssertNil(checker.status.releaseURL)
            UpdateHTTPProtocol.fixture.setReply(.release("v0.2.0"))
            await checker.check()
            XCTAssertEqual(checker.status.state, .updateAvailable)
            XCTAssertNil(checker.status.error)
            XCTAssertEqual(UpdateHTTPProtocol.fixture.requests.count, 2)
        }
    }

    func test_releaseLinks_rejectOtherOriginsAndMisleadingPaths() async {
        for link in ["http://github.com/haandol/storybird/releases/tag/v0.2.0",
                     "https://github.com.evil.test/haandol/storybird/releases/tag/v0.2.0",
                     "https://github.com/other/storybird/releases/tag/v0.2.0",
                     "https://github.com/haandol/storybird/releases/tag/v0.2.0/extra",
                     "https://github.com/haandol/storybird/releases/tag/v0.3.0",
                     "https://user@github.com/haandol/storybird/releases/tag/v0.2.0",
                     "https://github.com:443/haandol/storybird/releases/tag/v0.2.0",
                     "https://github.com/haandol/storybird/releases/tag/v0.2.0?redirect=1",
                     "https://github.com/haandol/storybird/releases/tag/v0.2.0#x",
                     "https://github.com/haandol/storybird/releases/tag/%76%30.2.0",
                     "file:///tmp/release"] {
            let (checker, session) = makeChecker()
            defer { session.invalidateAndCancel() }
            UpdateHTTPProtocol.fixture.setReply(.release("v0.2.0", url: link))
            await checker.check()
            XCTAssertEqual(checker.status.state, .failed, link)
            XCTAssertNil(checker.status.releaseURL)
        }
    }

    func test_redirectDelegate_refusesASecondRequest() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: StorybirdUpdateChecker.request())
        let response = try XCTUnwrap(HTTPURLResponse(url: StorybirdUpdateChecker.endpoint, statusCode: 302,
                                                   httpVersion: nil, headerFields: ["Location": "https://example.com"]))
        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            ReleaseRequestDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.com")!)) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(forwarded)
    }

    func test_mcpAndSettings_sharePendingCheckAndTerminalResultsWithoutProjectChanges() async throws {
        for profile in StorybirdMCPToolProfile.allCases {
            let (checker, session) = makeChecker()
            defer { session.invalidateAndCancel(); UpdateHTTPProtocol.fixture.finish() }
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = ProjectRepository(rootURL: root)
            let project = DemoProject(name: "Synthetic update check")
            try repository.saveProjects([project])
            let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let store = AppStore(repository: repository, updateChecker: checker)
            let originalProjects = store.projects
            let host = StorybirdExternalControlHost(store: store)
            let ipc = StorybirdAppIPCClient(sender: { await host.handle($0) },
                                           launcher: { throw StorybirdControlWireError.invalidMessage })
            let server = await StorybirdMCPService(client: ipc, toolProfile: profile).makeServer()
            let transport = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: transport.server)
            let client = Client(name: "Update check test", version: "1")
            do {
                _ = try await client.connect(transport: transport.client)
                let idle = try await call(client, "storybird_get_update_status")
                XCTAssertEqual(idle, checker.status)
                XCTAssertTrue(UpdateHTTPProtocol.fixture.requests.isEmpty)
                for name in ["storybird_check_for_updates", "storybird_get_update_status"] {
                    let result = try await client.callTool(name: name, arguments: ["url": "https://example.com"])
                    XCTAssertEqual(result.isError, true)
                }
                XCTAssertTrue(UpdateHTTPProtocol.fixture.requests.isEmpty)
                UpdateHTTPProtocol.fixture.setReply(.release("v0.2.0"), hold: true)
                let recordingOperation = store.beginStorageOperation(.recording)
                let checking = try await call(client, "storybird_check_for_updates")
                XCTAssertEqual(checking.state, .checking)
                XCTAssertEqual(checking.currentVersion, "0.1.13")
                XCTAssertEqual(checking.buildNumber, "14")
                _ = checker.startCheck() // Same action as the Settings button.
                let repeated = try await call(client, "storybird_check_for_updates")
                XCTAssertEqual(repeated, checking)
                try await waitForRequest()
                for _ in 0..<3 {
                    let cached = try await call(client, "storybird_get_update_status")
                    XCTAssertEqual(cached, checking)
                }
                XCTAssertEqual(UpdateHTTPProtocol.fixture.requests.count, 1)
                XCTAssertNotNil(store.storageChangeDisabledReason)
                store.endStorageOperation(recordingOperation)
                XCTAssertNil(store.storageChangeDisabledReason, "Network wait must not hold storage operations.")
                UpdateHTTPProtocol.fixture.finish()
                let completed = try await poll(client)
                XCTAssertEqual(completed, checker.status)
                XCTAssertEqual(completed.state, .updateAvailable)
                XCTAssertEqual(completed.latestVersion, "0.2.0")
                UpdateHTTPProtocol.fixture.setReply(UpdateHTTPReply(error: .timedOut))
                _ = try await call(client, "storybird_check_for_updates")
                let failure = try await poll(client)
                XCTAssertEqual(failure.state, .failed)
                XCTAssertNil(failure.releaseURL)
                XCTAssertNotNil(failure.error)
                UpdateHTTPProtocol.fixture.setReply(.release("v0.1.13"))
                await checker.check() // UI retry is immediately observable through MCP.
                let retried = try await call(client, "storybird_get_update_status")
                XCTAssertEqual(retried.state, .upToDate)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
                XCTAssertEqual(store.projects, originalProjects)
                XCTAssertNil(store.errorMessage)
                XCTAssertNil(store.storageChangeDisabledReason)
                await client.disconnect()
                await server.stop()
            } catch {
                UpdateHTTPProtocol.fixture.finish()
                await client.disconnect()
                await server.stop()
                throw error
            }
        }
    }

    private func call(_ client: Client, _ name: String) async throws -> AppUpdateStatus {
        let result = try await client.callTool(name: name)
        XCTAssertNotEqual(result.isError, true)
        let text = result.content.compactMap { if case let .text(text, _, _) = $0 { return text }; return nil }.joined()
        return try JSONDecoder().decode(AppUpdateStatus.self, from: Data(text.utf8))
    }

    private func poll(_ client: Client) async throws -> AppUpdateStatus {
        for _ in 0..<200 {
            let result = try await call(client, "storybird_get_update_status")
            if result.state != .checking { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Update check did not reach a terminal state.")
        return try await call(client, "storybird_get_update_status")
    }

    private func waitForRequest() async throws {
        for _ in 0..<200 {
            if !UpdateHTTPProtocol.fixture.requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Explicit check did not issue its GET.")
    }

    private func makeChecker(version: String? = "0.1.13") -> (StorybirdUpdateChecker, URLSession) {
        UpdateHTTPProtocol.fixture.reset()
        let configuration = StorybirdUpdateChecker.sessionConfiguration()
        configuration.protocolClasses = [UpdateHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        return (StorybirdUpdateChecker(currentVersion: version, buildNumber: "14", session: session), session)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("storybird-updates-\(UUID().uuidString)")
    }
}

struct UpdateHTTPReply: Sendable {
    var status = 200
    var body = "{}"
    var error: URLError.Code?

    static func release(_ tag: String, url: String? = nil) -> Self {
        let data = try! JSONSerialization.data(withJSONObject: ["tag_name": tag,
            "html_url": url ?? "https://github.com/haandol/storybird/releases/tag/\(tag)"])
        return Self(body: String(decoding: data, as: UTF8.self))
    }
}

/// URLProtocol callbacks run off the main actor; serialize their shared fixture.
final class UpdateHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var reply = UpdateHTTPReply.release("v0.2.0")
    private var hold = false
    private var pending: [UpdateHTTPProtocol] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    func reset() {
        finish()
        lock.withLock { recorded = []; reply = .release("v0.2.0"); hold = false }
    }
    func setReply(_ value: UpdateHTTPReply, hold: Bool = false) {
        lock.withLock { reply = value; self.hold = hold }
    }
    func start(_ handler: UpdateHTTPProtocol) {
        let response: UpdateHTTPReply? = lock.withLock {
            recorded.append(handler.request)
            if hold { pending.append(handler); return nil }
            return reply
        }
        if let response { handler.respond(response) }
    }
    func stop(_ handler: UpdateHTTPProtocol) {
        lock.withLock { pending.removeAll { $0 === handler } }
    }
    func finish() {
        let (handlers, response) = lock.withLock {
            let handlers = pending; pending = []; hold = false
            return (handlers, reply)
        }
        for handler in handlers { handler.respond(response) }
    }
}

final class UpdateHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = UpdateHTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture.start(self) }
    override func stopLoading() { Self.fixture.stop(self) }
    func respond(_ reply: UpdateHTTPReply) {
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
