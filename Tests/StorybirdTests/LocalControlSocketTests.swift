import Darwin
import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

final class LocalControlSocketTests: XCTestCase {
    func test_partialRequest_doesNotBlockIndependentConnection() throws {
        for partialBody in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let server = StorybirdLocalControlServer(rootURL: root, authorizePeer: { _ in true }) { request in
                StorybirdControlResponse(text: request.name)
            }
            try server.start()
            defer {
                server.stop()
                try? FileManager.default.removeItem(at: root)
            }
            let incomplete = try Self.connect(root)
            defer { Darwin.close(incomplete) }
            if partialBody {
                var length = UInt32(100).bigEndian
                _ = withUnsafeBytes(of: &length) { Darwin.write(incomplete, $0.baseAddress, $0.count) }
                var firstByte: UInt8 = 123
                _ = Darwin.write(incomplete, &firstByte, 1)
            }
            let query = try Self.connect(root)
            defer { Darwin.close(query) }
            try StorybirdControlWire.send(
                StorybirdControlRequest(name: "storybird_list_projects", argumentsJSON: Data("{}".utf8)),
                fileDescriptor: query
            )
            var descriptor = pollfd(fd: query, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 1_000)
            XCTAssertEqual(ready, 1, "Partial \(partialBody ? "body" : "header") blocked another request")
            if ready == 1 {
                let response = try StorybirdControlWire.receive(StorybirdControlResponse.self, fileDescriptor: query)
                XCTAssertEqual(response.text, "storybird_list_projects")
            }
        }
    }

    @MainActor
    func test_parallelPreviewDraftAndAudio_preserveReadyDraftAndRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let id = UUID()
        let target = try repository.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: false, duration: 2)
        var project = DemoProject(id: id, name: "Parallel socket fixture", recording: VideoRecordingAsset(
            filename: target.filename, duration: media.duration, width: media.width, height: media.height
        ))
        let draft = NarrationDraft(
            voiceProfileID: UUID(), text: "Synthetic narration", language: "english",
            filename: "ready.wav", state: .ready, duration: 1
        )
        try TestVideoFactory.makeToneWAV(
            at: repository.assetURL(projectID: id, filename: draft.filename), duration: 1
        )
        project.narrationDrafts = [draft]
        project.narrations = [NarrationClip(filename: draft.filename, text: draft.text, startTime: 0.4, duration: 1)]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let before = try XCTUnwrap(store.project(id: id))
        let host = StorybirdExternalControlHost(store: store)
        let server = StorybirdLocalControlServer(rootURL: root, authorizePeer: { _ in true }) {
            await host.handle($0)
        }
        try server.start()
        defer { server.stop() }
        let incomplete = try Self.connect(root)
        defer { Darwin.close(incomplete) }
        let arguments: [(String, [String: Any])] = [
            ("storybird_render_preview", ["project_id": id.uuidString, "time": 0.5]),
            ("storybird_get_narration_draft", ["project_id": id.uuidString, "draft_id": draft.id.uuidString]),
            ("storybird_render_audio_preview", ["project_id": id.uuidString, "start_time": 0, "duration": 2]),
        ]
        let requests = try arguments.map {
            StorybirdControlRequest(name: $0.0, argumentsJSON: try JSONSerialization.data(withJSONObject: $0.1))
        }
        for parallel in [true, false] {
            let results: [StorybirdControlResponse]
            if parallel {
                results = try await withThrowingTaskGroup(of: StorybirdControlResponse.self) { group in
                    for request in requests {
                        group.addTask { try await Self.call(request, root: root) }
                    }
                    var responses: [StorybirdControlResponse] = []
                    for try await response in group { responses.append(response) }
                    return responses
                }
            } else {
                var responses: [StorybirdControlResponse] = []
                for request in requests { responses.append(try await Self.call(request, root: root)) }
                results = responses
            }
            for response in results {
                XCTAssertFalse(response.isError, response.text)
                if let object = try JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any],
                   let path = object["path"] as? String {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
                    try FileManager.default.removeItem(atPath: path)
                }
            }
            XCTAssertEqual(store.project(id: id), before)
            XCTAssertTrue(results.contains { $0.imageData != nil })
        }
    }

    func test_untrustedConnection_isRejectedBeforeHandler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = StorybirdLocalControlServer(rootURL: root) { _ in
            XCTFail("Untrusted request reached handler")
            return StorybirdControlResponse(text: "unexpected")
        }
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let connection = try StorybirdControlConnection(fileDescriptor: Self.connect(root))
        defer { connection.close() }
        let response = try await connection.receive(StorybirdControlResponse.self)
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("untrusted"))
    }

    private static func call(_ request: StorybirdControlRequest, root: URL) async throws -> StorybirdControlResponse {
        let connection = try StorybirdControlConnection(fileDescriptor: connect(root))
        defer { connection.close() }
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                connection.close()
            } catch {}
        }
        defer { watchdog.cancel() }
        try await connection.send(request)
        return try await connection.receive(StorybirdControlResponse.self)
    }

    private static func connect(_ root: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StorybirdControlWireError.system(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        root.appendingPathComponent("control.sock").path.withCString { path in
            withUnsafeMutablePointer(to: &address.sun_path) {
                _ = strlcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), path, capacity)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw StorybirdControlWireError.system(error)
        }
        return fd
    }
}
