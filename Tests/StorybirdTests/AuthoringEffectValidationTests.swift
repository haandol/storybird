import Foundation
import StorybirdCore
@testable import Storybird
import XCTest

@MainActor
final class AuthoringEffectValidationTests: XCTestCase {
    /// Duplicate IDs must be an ordinary host error before transition indexing,
    /// regardless of existing suggestion state or the duplicated entry's payload.
    func test_fullReplacement_duplicateSuggestionIDs_preservesProjectAndHistory() async throws {
        for state in ClickSuggestionState.allCases {
            try await assertRejected("duplicate suggestion in \(state)", state: state) { host, before in
                var invalid = before
                invalid.name = "Valid name must not publish"
                var duplicate = try XCTUnwrap(invalid.suggestions.first)
                duplicate.splitTime += 0.1
                invalid.suggestions.append(duplicate)
                return try await replace(invalid, using: host)
            }
        }
    }

    /// Full replacement must reject raw spotlight opacity outside the normalized
    /// interval together with a valid project edit, without altering history.
    func test_fullReplacement_invalidSpotlightOpacity_preservesProjectAndHistory() async throws {
        for value in [-0.01, 1.01] {
            try await assertRejected("spotlight opacity \(value)") { host, before in
                var invalid = before
                invalid.name = "Valid name must not publish"
                guard case var .spotlight(spotlight) = invalid.effects[2] else {
                    throw EffectFixtureError.unexpectedEffect
                }
                spotlight.dimOpacity = value
                invalid.effects[2] = .spotlight(spotlight)
                return try await replace(invalid, using: host)
            }
        }
    }

    /// Both full-screen card owners reject malformed foreground/background colors
    /// even when their title and another style property are otherwise valid.
    func test_fullReplacement_invalidCardColors_preservesProjectAndHistory() async throws {
        for index in [0, 1] {
            for path in [\TextOverlayStyle.backgroundHex, \TextOverlayStyle.foregroundHex] {
                for color in ["#NOTHEX", "#fff"] {
                    try await assertRejected("card \(index) \(path) = \(color)") { host, before in
                        var invalid = before
                        try updateCard(&invalid, at: index) {
                            $0[keyPath: path] = color
                            $0.fontSize = 24
                        }
                        return try await replace(invalid, using: host)
                    }
                }
            }
        }
    }

    /// Narrow card updates must share publication validation; the color failure
    /// cannot leave the accompanying title and valid opacity partially saved.
    func test_narrowEffect_invalidCardColors_preservesProjectAndHistory() async throws {
        for index in [0, 1] {
            for field in ["background_hex", "foreground_hex"] {
                try await assertRejected("narrow card \(index) \(field)") { host, before in
                    try await command(host, "storybird_update_effect", [
                        "project_id": before.id.uuidString, "expected_revision": before.revision,
                        "effect_id": before.effects[index].id.uuidString,
                        "title": "Valid title must not publish", "background_opacity": 0.25,
                        field: "#NOTHEX",
                    ])
                }
            }
        }
    }

    /// Card JSON must retain invalid numeric values until strict decoding rejects
    /// them; mutating a model opacity setter would silently normalize the fixture.
    func test_fullReplacement_rawInvalidCardStyleNumbers_preservesProjectAndHistory() async throws {
        for index in [0, 1] {
            for (field, values) in [("backgroundOpacity", [-0.01, 1.01]), ("fontSize", [0.0, 0.999])] {
                for value in values {
                    try await assertRejected("raw card \(index) \(field) = \(value)") { host, before in
                        var object = try projectObject(before)
                        var effects = try XCTUnwrap(object["effects"] as? [[String: Any]])
                        let kind = index == 0 ? "title" : "cta"
                        var wrapper = try XCTUnwrap(effects[index][kind] as? [String: Any])
                        var card = try XCTUnwrap(wrapper["_0"] as? [String: Any])
                        var style = try XCTUnwrap(card["style"] as? [String: Any])
                        style[field] = value
                        card["style"] = style
                        card["title"] = "Valid title must not publish"
                        wrapper["_0"] = card
                        effects[index][kind] = wrapper
                        object["effects"] = effects
                        let data = try JSONSerialization.data(withJSONObject: object)
                        return try await command(host, "storybird_replace_project", [
                            "project_id": before.id.uuidString, "expected_revision": before.revision,
                            "project_json": String(decoding: data, as: UTF8.self),
                        ])
                    }
                }
            }
        }
    }

    /// Direct shared validation rejects nonfinite values that JSON cannot carry,
    /// and mutable card font sizes cannot bypass the decoder's minimum check.
    func test_sharedValidator_nonfiniteEffectsAndInvalidFonts_rejectsEveryOwner() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            var project = try fixtureProject()
            guard case var .spotlight(spotlight) = project.effects[2] else {
                throw EffectFixtureError.unexpectedEffect
            }
            spotlight.dimOpacity = value
            project.effects[2] = .spotlight(spotlight)
            XCTAssertThrowsError(try VideoProjectValidator.validate(project), "spotlight \(value)") {
                XCTAssertEqual($0 as? VideoProjectValidationError, .invalidEffect(spotlight.id))
            }
        }
        for index in [0, 1] {
            for value in [Double.nan, .infinity, -.infinity, 0, 0.999] {
                var project = try fixtureProject()
                try updateCard(&project, at: index) { $0.fontSize = value }
                XCTAssertThrowsError(try VideoProjectValidator.validate(project), "card \(index) font \(value)") {
                    XCTAssertEqual($0 as? VideoProjectValidationError, .invalidEffect(project.effects[index].id))
                }
            }
            var project = try fixtureProject()
            try updateCard(&project, at: index) { $0.backgroundOpacity = .nan }
            XCTAssertThrowsError(try VideoProjectValidator.validate(project), "card \(index) opacity NaN") {
                XCTAssertEqual($0 as? VideoProjectValidationError, .invalidEffect(project.effects[index].id))
            }
        }
    }

    /// Valid opacity endpoints and minimum font size remain supported through
    /// replacement and narrow editing, with exactly one undo entry per edit.
    func test_effectStyleBoundaries_fullAndNarrowEditsRemainUndoable() async throws {
        for endpoint in [0.0, 1.0] {
            try await withStore { store, original in
                let host = StorybirdExternalControlHost(store: store)
                var changed = original
                for index in [0, 1] {
                    try updateCard(&changed, at: index) {
                        $0.backgroundOpacity = endpoint
                        $0.fontSize = endpoint == 0 ? 1 : 256
                        $0.foregroundHex = "#aBcDeF"
                        $0.backgroundHex = "#000000"
                    }
                }
                guard case var .spotlight(spotlight) = changed.effects[2] else {
                    throw EffectFixtureError.unexpectedEffect
                }
                spotlight.dimOpacity = endpoint
                changed.effects[2] = .spotlight(spotlight)
                let response = try await replace(changed, using: host)
                XCTAssertFalse(response.isError, response.text)
                let saved = try XCTUnwrap(store.project(id: original.id))
                XCTAssertEqual(saved.revision, original.revision + 1)
                assertContent(saved, equals: changed)
                assertContent(try store.undo(projectID: saved.id), equals: original)
                XCTAssertThrowsError(try store.undo(projectID: saved.id))
                assertContent(try store.redo(projectID: saved.id), equals: changed)
                for index in [0, 1] {
                    let before = try XCTUnwrap(store.project(id: original.id))
                    let result = try await command(host, "storybird_update_effect", [
                        "project_id": before.id.uuidString, "expected_revision": before.revision,
                        "effect_id": before.effects[index].id.uuidString,
                        "title": "Another valid title", "background_opacity": endpoint,
                        "font_size": 1, "foreground_hex": "#FFFFFF", "background_hex": "#000000",
                    ])
                    XCTAssertFalse(result.isError, result.text)
                    let updated = try XCTUnwrap(store.project(id: original.id))
                    XCTAssertEqual(updated.revision, before.revision + 1)
                    assertContent(try store.undo(projectID: before.id), equals: before)
                    assertContent(try store.redo(projectID: before.id), equals: updated)
                }
            }
        }
    }

    /// Duplicate rejection must not weaken terminal-state rules: resetting a
    /// terminal suggestion or dropping it while its Cue survives stays invalid.
    func test_terminalSuggestions_invalidTransitionsStillPreserveHistory() async throws {
        for state in [ClickSuggestionState.applied, .rejected] {
            for remove in [false, true] {
                try await assertRejected("terminal \(state), remove \(remove)", state: state) { host, before in
                    var invalid = before
                    invalid.name = "Valid name must not publish"
                    if remove { invalid.suggestions.removeAll() }
                    else { invalid.suggestions[0].state = .pending }
                    return try await replace(invalid, using: host)
                }
            }
        }
    }

    /// Existing terminal metadata and cleanup after deleting its Cue remain legal;
    /// undo restores both the Cue and its original terminal suggestion state.
    func test_terminalSuggestions_validEditsAndCueCleanupRemainUndoable() async throws {
        for state in [ClickSuggestionState.applied, .rejected] {
            try await withStore(state: state) { store, original in
                let host = StorybirdExternalControlHost(store: store)
                var renamed = original
                renamed.name = "Valid terminal-preserving edit"
                let edited = try await replace(renamed, using: host)
                XCTAssertFalse(edited.isError, edited.text)
                let before = try XCTUnwrap(store.project(id: original.id))
                XCTAssertEqual(before.suggestions[0].state, state)
                var removed = before
                removed.clicks.removeAll()
                removed.suggestions.removeAll()
                let response = try await replace(removed, using: host)
                XCTAssertFalse(response.isError, response.text)
                let saved = try XCTUnwrap(store.project(id: original.id))
                XCTAssertEqual(saved.revision, before.revision + 1)
                XCTAssertEqual(saved.effects, before.effects)
                XCTAssertTrue(saved.clicks.isEmpty)
                XCTAssertTrue(saved.suggestions.isEmpty)
                assertContent(try store.undo(projectID: saved.id), equals: before)
                assertContent(try store.undo(projectID: saved.id), equals: original)
                XCTAssertThrowsError(try store.undo(projectID: saved.id))
            }
        }
    }

    /// Populates both history branches before calling the real host, then proves
    /// rejection leaves bytes, full project and the exact undo/redo contents intact.
    private func assertRejected(
        _ label: String,
        state: ClickSuggestionState = .pending,
        request: (StorybirdExternalControlHost, DemoProject) async throws -> StorybirdControlResponse
    ) async throws {
        try await withStore(state: state) { store, original in
            var prior = original
            prior.name = "Existing undo edit"
            prior = try store.saveProject(prior, expectedRevision: original.revision)
            var future = prior
            future.summary = "Existing redo edit"
            future = try store.saveProject(future, expectedRevision: prior.revision)
            let before = try store.undo(projectID: original.id)
            let library = store.repository.rootURL.appendingPathComponent("library.json")
            let bytes = try Data(contentsOf: library)
            let host = StorybirdExternalControlHost(store: store)
            let response = try await request(host, before)
            XCTAssertTrue(response.isError, "\(label): \(response.text.prefix(180))")
            XCTAssertTrue(store.project(id: original.id) == before, "\(label): project changed")
            XCTAssertEqual(store.project(id: original.id)?.revision, before.revision, label)
            XCTAssertEqual(try Data(contentsOf: library), bytes, label)
            let subsequent = try await command(host, "storybird_get_project", ["project_id": before.id.uuidString])
            XCTAssertFalse(subsequent.isError, "\(label): host must remain callable")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fetched = try decoder.decode(DemoProject.self, from: Data(subsequent.text.utf8))
            XCTAssertEqual(fetched.revision, before.revision, label)
            guard response.isError else { return }
            assertContent(try store.redo(projectID: before.id), equals: future)
            assertContent(try store.undo(projectID: before.id), equals: before)
            assertContent(try store.undo(projectID: before.id), equals: original)
            XCTAssertThrowsError(try store.undo(projectID: before.id))
        }
    }

    /// Exercises strict whole-project decoding and the app-owned publication path.
    private func replace(_ project: DemoProject, using host: StorybirdExternalControlHost) async throws -> StorybirdControlResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try await command(host, "storybird_replace_project", [
            "project_id": project.id.uuidString, "expected_revision": project.revision,
            "project_json": String(decoding: try encoder.encode(project), as: UTF8.self),
        ])
    }

    /// Uses the app's real external-control command handler without native capture.
    private func command(
        _ host: StorybirdExternalControlHost, _ name: String, _ arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        await host.handle(StorybirdControlRequest(
            name: name, argumentsJSON: try JSONSerialization.data(withJSONObject: arguments)
        ))
    }

    /// Converts a valid fixture to raw JSON so malformed style values avoid setter clamping.
    private func projectObject(_ project: DemoProject) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(project)) as? [String: Any])
    }

    /// Keeps card timing fixed while mixing an ordinary title change with a style edit.
    private func updateCard(
        _ project: inout DemoProject, at index: Int, style: (inout TextOverlayStyle) -> Void
    ) throws {
        switch project.effects[index] {
        case var .title(card):
            card.title = "Valid accompanying title"
            style(&card.style)
            project.effects[index] = .title(card)
        case var .cta(card):
            card.title = "Valid accompanying title"
            style(&card.style)
            project.effects[index] = .cta(card)
        default:
            throw EffectFixtureError.unexpectedEffect
        }
    }

    /// History advances publication metadata while retaining every editable value.
    private func assertContent(_ actual: DemoProject, equals expected: DemoProject) {
        var comparable = actual
        comparable.revision = expected.revision
        comparable.updatedAt = expected.updatedAt
        XCTAssertEqual(comparable, expected)
    }

    /// Creates only a temporary metadata library; no GUI, model, capture or user
    /// storage is involved. Every normally completed test cleans up its own root.
    private func withStore(
        state: ClickSuggestionState = .pending,
        body: (AppStore, DemoProject) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storybird-effect-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        try repository.prepare()
        var project = try fixtureProject()
        project.suggestions[0].state = state
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        try await body(store, XCTUnwrap(store.project(id: project.id)))
    }

    /// Supplies one suggested Cue, legal title/CTA slots and an overlapping
    /// spotlight so invalid tests isolate properties rather than structural timing.
    private func fixtureProject() throws -> DemoProject {
        var project = DemoProject(
            name: "Synthetic effect validation",
            recording: VideoRecordingAsset(filename: "synthetic.mp4", duration: 10, width: 1280, height: 720)
        )
        project = try VideoTimelineEditor.addClickCue(to: project, at: 1, x: 0.5, y: 0.5)
        project.clicks[0].description.text = "Original description"
        project.clicks[0].cueSubtitle.text = "Original subtitle"
        project = try DemoEffectEditor.insertTitle(in: project, after: nil, duration: 1, title: "Original title")
        project = try DemoEffectEditor.insertCTA(in: project, duration: 1, title: "Original CTA", buttonLabel: "Continue")
        project.effects.append(.spotlight(SpotlightEffect(
            startTime: 2, endTime: 3, x: 0.2, y: 0.2, width: 0.5, height: 0.5
        )))
        try VideoProjectValidator.validate(project)
        return project
    }
}

private enum EffectFixtureError: Error { case unexpectedEffect }
