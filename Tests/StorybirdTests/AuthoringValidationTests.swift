import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class AuthoringValidationTests: XCTestCase {
    /// Full replacement must reject each malformed Cue window together with valid
    /// text edits, retaining persisted bytes and both existing history branches.
    func test_fullReplacement_invalidCueWindows_preservesProjectAndHistory() async throws {
        let starts: [WritableKeyPath<TimedPointerClick, Double>] = [
            \.indicator.startTime, \.description.startTime, \.cueSubtitle.startTime,
        ]
        let ends: [WritableKeyPath<TimedPointerClick, Double>] = [
            \.indicator.endTime, \.description.endTime, \.cueSubtitle.endTime,
        ]
        for path in starts {
            for value in [-0.001, 1.001] {
                try await assertRejectedReplacement("\(path) = \(value)") {
                    $0.clicks[0][keyPath: path] = value
                }
            }
        }
        for path in ends {
            for value in [0.0, 1.0, 10.001] {
                try await assertRejectedReplacement("\(path) = \(value)") {
                    $0.clicks[0][keyPath: path] = value
                }
            }
        }
    }

    /// Persisted description coordinates remain normalized even in automatic mode;
    /// ring sizes must be positive and opacity must include only zero through one.
    func test_fullReplacement_invalidCueGeometry_preservesProjectAndHistory() async throws {
        for position in ClickDescriptionPosition.allCases {
            for path in [\TimedPointerClick.description.x, \TimedPointerClick.description.y] {
                for value in [-0.001, 1.001] {
                    try await assertRejectedReplacement("\(position) \(path) = \(value)") {
                        $0.clicks[0].description.position = position
                        $0.clicks[0][keyPath: path] = value
                    }
                }
            }
        }
        for path in [\TimedPointerClick.x, \TimedPointerClick.y, \TimedPointerClick.indicator.opacity] {
            for value in [-0.001, 1.001] {
                try await assertRejectedReplacement("\(path) = \(value)") {
                    $0.clicks[0][keyPath: path] = value
                }
            }
        }
        for value in [-1.0, 0.0] {
            try await assertRejectedReplacement("indicator size = \(value)") {
                $0.clicks[0].indicator.size = value
            }
        }
    }

    /// Every Cue and independent subtitle color reaches the shared validator
    /// through JSON replacement instead of relying on narrow editing tools.
    func test_fullReplacement_invalidOverlayColors_preservesProjectAndHistory() async throws {
        let cuePaths: [WritableKeyPath<TimedPointerClick, String>] = [
            \.indicator.colorHex,
            \.description.style.backgroundHex, \.description.style.foregroundHex,
            \.cueSubtitle.style.backgroundHex, \.cueSubtitle.style.foregroundHex,
        ]
        for color in ["", "#FFF", "1234567", "#12345G", "#12345678"] {
            for path in cuePaths {
                try await assertRejectedReplacement("\(path) = \(color)") {
                    $0.clicks[0][keyPath: path] = color
                }
            }
            for path in [\TextOverlayStyle.backgroundHex, \TextOverlayStyle.foregroundHex] {
                try await assertRejectedReplacement("subtitle \(path) = \(color)") {
                    $0.subtitles[0].style[keyPath: path] = color
                }
            }
        }
    }

    /// Raw JSON preserves out-of-range opacity until the production host decodes
    /// it, so valid text in the same replacement must never be partially saved.
    func test_fullReplacement_rawInvalidTextOpacity_preservesProjectAndHistory() async throws {
        for owner in ["description", "cueSubtitle", "subtitle"] {
            for value in [-0.01, 1.01] {
                try await assertRejectedReplacement(
                    "\(owner) raw backgroundOpacity = \(value)",
                    rawStyle: (owner, "backgroundOpacity", value)
                ) { _ in }
            }
        }
    }

    /// Font sizes below one must be rejected before decoding can clamp them;
    /// each text owner uses the same full-replacement atomicity checks.
    func test_fullReplacement_rawInvalidFontSize_preservesProjectAndHistory() async throws {
        for owner in ["description", "cueSubtitle", "subtitle"] {
            for value in [0.0, 0.999] {
                try await assertRejectedReplacement(
                    "\(owner) raw fontSize = \(value)",
                    rawStyle: (owner, "fontSize", value)
                ) { _ in }
            }
        }
    }

    /// Ordinary project decoding retains its supported legacy clamping, while
    /// the same serialized fields are rejected by strict host replacement tests.
    func test_normalProjectDecode_outOfRangeTextStyles_preservesClampingCompatibility() throws {
        let project = fixtureProject()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for owner in ["description", "cueSubtitle", "subtitle"] {
            for (property, values) in [
                ("backgroundOpacity", [-0.01, 1.01]),
                ("fontSize", [0.0, 0.999]),
            ] {
                for value in values {
                    let data = try serializedProject(project, rawStyle: (owner, property, value))
                    let decoded = try decoder.decode(DemoProject.self, from: data)
                    var expected = project
                    var style: TextOverlayStyle
                    switch owner {
                    case "description": style = expected.clicks[0].description.style
                    case "cueSubtitle": style = expected.clicks[0].cueSubtitle.style
                    default: style = expected.subtitles[0].style
                    }
                    if property == "backgroundOpacity" {
                        style.backgroundOpacity = value < 0 ? 0 : 1
                    } else {
                        style.fontSize = 1
                    }
                    switch owner {
                    case "description": expected.clicks[0].description.style = style
                    case "cueSubtitle": expected.clicks[0].cueSubtitle.style = style
                    default: expected.subtitles[0].style = style
                    }
                    XCTAssertEqual(decoded, expected, "\(owner) \(property) = \(value)")
                    XCTAssertNoThrow(try VideoProjectValidator.validate(decoded))
                }
            }
        }
    }

    /// Direct validation covers nonfinite values that JSON cannot represent,
    /// ensuring native edits also reject malformed Cue metadata before saving.
    func test_sharedValidator_nonfiniteCueFields_rejectsEveryField() throws {
        let paths: [WritableKeyPath<TimedPointerClick, Double>] = [
            \.time, \.sourceTime, \.x, \.y,
            \.indicator.startTime, \.indicator.endTime, \.indicator.size, \.indicator.opacity,
            \.description.startTime, \.description.endTime, \.description.x, \.description.y,
            \.description.style.fontSize, \.description.style.backgroundOpacity,
            \.cueSubtitle.startTime, \.cueSubtitle.endTime,
            \.cueSubtitle.style.fontSize, \.cueSubtitle.style.backgroundOpacity,
        ]
        for path in paths {
            for value in [Double.nan, .infinity, -.infinity] {
                var project = fixtureProject()
                project.clicks[0][keyPath: path] = value
                // Opacity setters normalize infinities; only values retained by
                // the model reach the publication validator.
                guard !project.clicks[0][keyPath: path].isFinite else { continue }
                XCTAssertThrowsError(try VideoProjectValidator.validate(project), "\(path) = \(value)") {
                    XCTAssertEqual($0 as? VideoProjectValidationError, .invalidClick(project.clicks[0].id))
                }
            }
        }
    }

    /// Mutable text styles need publication checks independently of constructor
    /// defaults and JSON decoding, across both Cue components and subtitles.
    func test_sharedValidator_invalidTextStyles_rejectsCueAndIndependentSubtitle() throws {
        for value in [-1.0, 0.0, 0.999, .nan, .infinity, -.infinity] {
            for path in [\TimedPointerClick.description.style.fontSize, \TimedPointerClick.cueSubtitle.style.fontSize] {
                var project = fixtureProject()
                project.clicks[0][keyPath: path] = value
                XCTAssertThrowsError(try VideoProjectValidator.validate(project), "\(path) = \(value)") {
                    XCTAssertEqual($0 as? VideoProjectValidationError, .invalidClick(project.clicks[0].id))
                }
            }
            var project = fixtureProject()
            project.subtitles[0].style.fontSize = value
            XCTAssertThrowsError(try VideoProjectValidator.validate(project), "subtitle font = \(value)") {
                XCTAssertEqual($0 as? VideoProjectValidationError, .invalidSubtitle(project.subtitles[0].id))
            }
        }
        var project = fixtureProject()
        project.subtitles[0].style.backgroundOpacity = .nan
        XCTAssertThrowsError(try VideoProjectValidator.validate(project)) {
            XCTAssertEqual($0 as? VideoProjectValidationError, .invalidSubtitle(project.subtitles[0].id))
        }
    }

    /// Inclusive coordinate/opacity endpoints, positive sizes and whole-project
    /// windows publish once through the host and remain reversible as one edit.
    func test_fullReplacement_validBoundaries_publishesOneUndoableEdit() async throws {
        for endpoint in [0.0, 1.0] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (store, original) = try fixtureStore(at: root)
            var edited = original
            edited.clicks[0].x = endpoint
            edited.clicks[0].y = 1 - endpoint
            edited.clicks[0].indicator.startTime = endpoint
            edited.clicks[0].indicator.endTime = 10
            edited.clicks[0].indicator.size = endpoint == 0 ? .leastNonzeroMagnitude : 100
            edited.clicks[0].indicator.opacity = endpoint
            edited.clicks[0].indicator.colorHex = "#aBcDeF"
            edited.clicks[0].description.position = endpoint == 0 ? .custom : .automatic
            edited.clicks[0].description.x = endpoint
            edited.clicks[0].description.y = 1 - endpoint
            edited.clicks[0].description.startTime = endpoint
            edited.clicks[0].description.endTime = 10
            edited.clicks[0].cueSubtitle.startTime = endpoint
            edited.clicks[0].cueSubtitle.endTime = 10
            edited.clicks[0].cueSubtitle.position = endpoint == 0 ? .top : .bottom
            let style = TextOverlayStyle(
                backgroundHex: "#000000", backgroundOpacity: endpoint,
                foregroundHex: "#fFfFfF", fontSize: endpoint == 0 ? 1 : 256
            )
            edited.clicks[0].description.style = style
            edited.clicks[0].cueSubtitle.style = style
            edited.subtitles[0].startTime = 0
            edited.subtitles[0].endTime = 10
            edited.subtitles[0].style = style
            let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let response = try await replace(edited, in: store, expectedRevision: original.revision)
            XCTAssertFalse(response.isError, response.text)
            let saved = try XCTUnwrap(store.project(id: original.id))
            XCTAssertEqual(saved.revision, original.revision + 1)
            assertContent(saved, equals: edited)
            XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes)
            XCTAssertEqual(try store.repository.loadProjects().first?.clicks, edited.clicks)
            assertContent(try store.undo(projectID: original.id), equals: original)
            XCTAssertThrowsError(try store.undo(projectID: original.id))
            assertContent(try store.redo(projectID: original.id), equals: edited)
            XCTAssertThrowsError(try store.redo(projectID: original.id))
        }
    }

    /// Incomplete Cue text remains editable; completeness belongs to export,
    /// while a click at zero may start all three components at that same instant.
    func test_sharedValidator_zeroTimeIncompleteCue_acceptsValidEditingState() throws {
        var project = fixtureProject()
        project.clicks[0].time = 0
        project.clicks[0].sourceTime = 0
        project.clicks[0].description.text = ""
        project.clicks[0].cueSubtitle.text = " "
        XCTAssertNoThrow(try VideoProjectValidator.validate(project))
    }

    /// Seeds undo and redo before each malformed request, so rejection must
    /// preserve actual history contents as well as bytes, revision and project.
    /// Optional raw styles bypass model setters only after valid text edits are encoded.
    private func assertRejectedReplacement(
        _ label: String,
        rawStyle: (owner: String, property: String, value: Double)? = nil,
        mutate: (inout DemoProject) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original) = try fixtureStore(at: root)
        var prior = original
        prior.clicks[0].description.text = "Existing edit"
        prior = try store.saveProject(prior, expectedRevision: original.revision)
        var future = prior
        future.clicks[0].cueSubtitle.text = "Existing redo"
        future = try store.saveProject(future, expectedRevision: prior.revision)
        let before = try store.undo(projectID: original.id)
        let bytes = try Data(contentsOf: root.appendingPathComponent("library.json"))
        var invalid = before
        invalid.clicks[0].description.text = "Valid text that must not be partially saved"
        invalid.subtitles[0].text = "Another valid edit that must not be saved"
        mutate(&invalid)
        let response = try await replace(
            invalid, in: store, expectedRevision: before.revision, rawStyle: rawStyle
        )
        XCTAssertTrue(response.isError, "\(label): \(response.text)", file: file, line: line)
        XCTAssertEqual(store.project(id: before.id), before, label, file: file, line: line)
        XCTAssertEqual(store.project(id: before.id)?.revision, before.revision, label, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), bytes, label, file: file, line: line)
        // Stop after a failed rejection to keep the regression signal on the
        // original invalid commit rather than its downstream history changes.
        guard response.isError else { return }
        assertContent(try store.redo(projectID: before.id), equals: future, file: file, line: line)
        assertContent(try store.undo(projectID: before.id), equals: before, file: file, line: line)
        assertContent(try store.undo(projectID: before.id), equals: original, file: file, line: line)
        XCTAssertThrowsError(try store.undo(projectID: before.id), label, file: file, line: line)
    }

    /// Exercises the production app host with the full project JSON exposed to
    /// MCP clients, including raw malformed styles, revision and atomic publication.
    private func replace(
        _ project: DemoProject,
        in store: AppStore,
        expectedRevision: Int,
        rawStyle: (owner: String, property: String, value: Double)? = nil
    ) async throws -> StorybirdControlResponse {
        let arguments: [String: Any] = [
            "project_id": project.id.uuidString,
            "expected_revision": expectedRevision,
            "project_json": String(decoding: try serializedProject(project, rawStyle: rawStyle), as: UTF8.self),
        ]
        return await StorybirdExternalControlHost(store: store).handle(StorybirdControlRequest(
            name: "storybird_replace_project",
            argumentsJSON: try JSONSerialization.data(withJSONObject: arguments)
        ))
    }

    /// Mutates the serialized dictionary rather than model properties so invalid
    /// opacity and font size arrive unchanged at the host's real JSON decoder.
    private func serializedProject(
        _ project: DemoProject,
        rawStyle: (owner: String, property: String, value: Double)?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        guard let rawStyle else { return data }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if rawStyle.owner == "subtitle" {
            var subtitles = try XCTUnwrap(object["subtitles"] as? [[String: Any]])
            var style = try XCTUnwrap(subtitles[0]["style"] as? [String: Any])
            style[rawStyle.property] = rawStyle.value
            subtitles[0]["style"] = style
            object["subtitles"] = subtitles
        } else {
            var clicks = try XCTUnwrap(object["clicks"] as? [[String: Any]])
            var component = try XCTUnwrap(clicks[0][rawStyle.owner] as? [String: Any])
            var style = try XCTUnwrap(component["style"] as? [String: Any])
            style[rawStyle.property] = rawStyle.value
            component["style"] = style
            clicks[0][rawStyle.owner] = component
            object["clicks"] = clicks
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Compares all restored content while allowing undo's monotonic revision
    /// and publication timestamp to advance under the existing history contract.
    private func assertContent(
        _ actual: DemoProject,
        equals expected: DemoProject,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var comparable = actual
        comparable.revision = expected.revision
        comparable.updatedAt = expected.updatedAt
        XCTAssertEqual(comparable, expected, file: file, line: line)
    }

    /// Isolates publication tests in a temporary repository. Metadata edits
    /// neither decode video nor require a GUI, capture permission or user data.
    private func fixtureStore(at root: URL) throws -> (AppStore, DemoProject) {
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        let project = fixtureProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        return (store, try XCTUnwrap(store.project(id: project.id)))
    }

    /// Supplies deterministic legal windows and styles without media or scene
    /// remapping, so a rejection identifies the property under test.
    private func fixtureProject() -> DemoProject {
        var cue = TimedPointerClick(time: 1, x: 0.5, y: 0.5)
        cue.indicator.startTime = 0
        cue.indicator.endTime = 2
        cue.description.startTime = 0
        cue.description.endTime = 2
        cue.description.text = "Description"
        cue.cueSubtitle.startTime = 0
        cue.cueSubtitle.endTime = 2
        cue.cueSubtitle.text = "Cue subtitle"
        return DemoProject(
            name: "Synthetic validation project",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 10, width: 1280, height: 720),
            clicks: [cue],
            subtitles: [TimedSubtitle(startTime: 0, endTime: 2, text: "Independent subtitle")]
        )
    }
}
