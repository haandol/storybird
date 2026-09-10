import Foundation
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

@MainActor
final class MCPFeatureParityTests: XCTestCase {
    func test_toolDefinitions_voiceNarrationExposeSafeAgentSurface() {
        let names = Set(
            StorybirdMCPService.toolDefinitions.map(\.name)
        )

        XCTAssertTrue(names.contains("storybird_list_voice_profiles"))
        XCTAssertTrue(names.contains("storybird_generate_narration"))
        XCTAssertTrue(names.contains("storybird_update_narration"))
        XCTAssertTrue(names.contains("storybird_delete_narration"))
        XCTAssertFalse(names.contains("storybird_create_voice_profile"))
        XCTAssertFalse(names.contains("storybird_record_voice_profile"))
        XCTAssertFalse(names.contains("storybird_delete_voice_profile"))
        XCTAssertFalse(names.contains("storybird_prepare_voice_model"))
    }

    func test_toolDefinitions_updateNarration_supportsTextRegeneration() throws {
        let properties = try propertyNames(
            for: "storybird_update_narration"
        )

        XCTAssertTrue(properties.contains("text"))
        XCTAssertTrue(properties.contains("language"))
        XCTAssertTrue(properties.contains("start_time"))
        XCTAssertTrue(properties.contains("volume"))
    }
    func test_toolDefinitions_clipEditingOperations_areExposed() {
        let available = Set(
            StorybirdMCPService.toolDefinitions.map(\.name)
        )
        let required = Set([
            "storybird_split_clip",
            "storybird_trim_clip",
            "storybird_delete_clip",
            "storybird_move_clip",
            "storybird_set_clip_speed",
            "storybird_insert_freeze",
        ])

        XCTAssertEqual(required.subtracting(available), [])
        for name in required {
            XCTAssertEqual(
                StorybirdMCPService.toolDefinitions.first {
                    $0.name == name
                }?.annotations.destructiveHint,
                false,
                "\(name) preserves the original recording and is undoable."
            )
        }
    }

    func test_toolDefinitions_remainingNativeEditingOperations_areExposed() {
        let available = Set(
            StorybirdMCPService.toolDefinitions.map(\.name)
        )
        let required = Set([
            "storybird_abort_session",
            "storybird_create_project",
            "storybird_create_click",
            "storybird_delete_click",
            "storybird_delete_subtitle",
            "storybird_create_spotlight",
            "storybird_create_pan_zoom",
            "storybird_insert_title",
            "storybird_insert_cta",
            "storybird_update_effect",
            "storybird_delete_effect",
            "storybird_update_suggestion",
            "storybird_apply_suggestion",
            "storybird_reject_suggestion",
        ])

        XCTAssertEqual(
            required.subtracting(available),
            [],
            "Every native editing operation must have an MCP command."
        )
    }

    func test_toolDefinitions_mutatingProjectTools_requireExpectedRevision() throws {
        let mutationTools = [
            "storybird_replace_project",
            "storybird_split_clip",
            "storybird_trim_clip",
            "storybird_delete_clip",
            "storybird_move_clip",
            "storybird_set_clip_speed",
            "storybird_insert_freeze",
            "storybird_undo_project",
            "storybird_redo_project",
            "storybird_update_project",
            "storybird_update_click",
            "storybird_upsert_subtitle",
        ]

        for name in mutationTools {
            let schema = try schemaObject(for: name)
            let required = Set(schema["required"] as? [String] ?? [])
            XCTAssertTrue(
                required.contains("expected_revision"),
                "\(name) must reject stale project state."
            )
        }
    }

    func test_toolDefinitions_targetedLayerTools_coverInspectorProperties() throws {
        let clickProperties = try propertyNames(
            for: "storybird_update_click"
        )
        let expectedClickProperties = Set([
            "project_id",
            "expected_revision",
            "click_id",
            "time",
            "button",
            "x",
            "y",
            "indicator_start_time",
            "indicator_end_time",
            "indicator_color_hex",
            "indicator_size",
            "indicator_opacity",
            "description",
            "description_start_time",
            "description_end_time",
            "description_position",
            "description_x",
            "description_y",
            "description_background_hex",
            "description_background_opacity",
            "description_foreground_hex",
            "description_font_size",
            "subtitle",
            "subtitle_start_time",
            "subtitle_end_time",
            "subtitle_position",
            "subtitle_background_hex",
            "subtitle_background_opacity",
            "subtitle_foreground_hex",
            "subtitle_font_size",
        ])
        XCTAssertEqual(
            expectedClickProperties.subtracting(clickProperties),
            []
        )

        let subtitleProperties = try propertyNames(
            for: "storybird_upsert_subtitle"
        )
        XCTAssertTrue(
            subtitleProperties.isSuperset(
                of: [
                    "project_id",
                    "expected_revision",
                    "subtitle_id",
                    "start_time",
                    "end_time",
                    "text",
                    "position",
                    "background_hex",
                    "background_opacity",
                    "foreground_hex",
                    "font_size",
                ]
            )
        )
    }

    func test_externalControl_createProject_matchesNativeProjectCreation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(
            repository: ProjectRepository(rootURL: root)
        )
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "name": "MCP project",
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_create_project",
                argumentsJSON: arguments
            )
        )

        XCTAssertFalse(response.isError)
        XCTAssertEqual(store.projects.first?.name, "MCP project")
        XCTAssertEqual(store.projects.first?.revision, 0)
    }

    func test_externalControl_subtitleStyleUpdatePreservesOmittedFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        var subtitle = TimedSubtitle(
            startTime: 0,
            endTime: 2,
            text: "한국어 tutorial",
            position: .top
        )
        subtitle.style.foregroundHex = "#AABBCC"
        subtitle.style.fontSize = 28
        project.subtitles = [subtitle]
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)

        let response = try await request(
            host,
            name: "storybird_upsert_subtitle",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "subtitle_id": subtitle.id.uuidString,
                "start_time": 1.0,
                "end_time": 3.0,
                "font_size": 32.0,
                "foreground_hex": "#112233",
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        let saved = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.subtitles[0].text, subtitle.text)
        XCTAssertEqual(saved.subtitles[0].position, .top)
        XCTAssertEqual(saved.subtitles[0].style.fontSize, 32)
        XCTAssertEqual(saved.subtitles[0].style.foregroundHex, "#112233")
    }

    func test_externalControl_subtitleRejectsInvalidTargetAndPositionWithoutMutation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let before = try XCTUnwrap(store.project(id: project.id))
        for invalid: [String: Any] in [
            ["subtitle_id": UUID().uuidString],
            ["subtitle_id": "invalid-id"],
            ["position": "center"],
            ["start_time": -1.0],
            ["background_opacity": 2.0],
        ] {
            var arguments: [String: Any] = [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "text": "Keep valid projects intact",
                "start_time": 0.0,
                "end_time": 2.0,
            ]
            arguments.merge(invalid) { _, value in value }
            let response = try await request(
                host,
                name: "storybird_upsert_subtitle",
                arguments: arguments
            )
            XCTAssertTrue(response.isError, "\(invalid): \(response.text)")
            XCTAssertEqual(store.project(id: project.id), before)
        }
    }

    func test_externalControl_setClipSpeed_matchesNativeTimelineEditor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.clicks = [
            TimedPointerClick(
                sourceTime: 2,
                time: 2,
                x: 0.5,
                y: 0.5
            ),
        ]
        try repository.saveProjects([project])
        let expected = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: project.clips[0].id,
            rate: 2
        )
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "clip_id": project.clips[0].id.uuidString,
                "rate": 2,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_set_clip_speed",
                argumentsJSON: arguments
            )
        )
        guard !response.isError else {
            return XCTFail(response.text)
        }
        let stored = try XCTUnwrap(store.project(id: project.id))

        XCTAssertEqual(stored.clips, expected.clips)
        XCTAssertEqual(stored.clicks, expected.clicks)
        XCTAssertEqual(stored.revision, 1)
    }

    func test_externalControl_clipCommands_matchNativeTimelineEditor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let project = validVideoProject()
        try repository.saveProjects([project])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let originalClipID = try XCTUnwrap(project.clips.first?.id)

        var response = try await request(
            host,
            name: "storybird_split_clip",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "clip_id": originalClipID.uuidString,
                "source_time": 2.5,
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        var stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.clips.count, 2)
        XCTAssertEqual(stored.revision, 1)

        let firstClipID = stored.clips[0].id
        let secondClipID = stored.clips[1].id
        let stale = try await request(
            host,
            name: "storybird_trim_clip",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "clip_id": secondClipID.uuidString,
                "source_start": 3.0,
                "source_end": 5.0,
            ]
        )
        XCTAssertTrue(stale.isError)
        XCTAssertEqual(store.project(id: project.id)?.revision, 1)

        response = try await request(
            host,
            name: "storybird_trim_clip",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 1,
                "clip_id": secondClipID.uuidString,
                "source_start": 3.0,
                "source_end": 5.0,
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.clips[1].sourceStart, 3.0)
        XCTAssertEqual(stored.revision, 2)

        response = try await request(
            host,
            name: "storybird_move_clip",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 2,
                "clip_id": secondClipID.uuidString,
                "destination": 0,
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.clips.first?.id, secondClipID)
        XCTAssertEqual(stored.revision, 3)

        response = try await request(
            host,
            name: "storybird_insert_freeze",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 3,
                "clip_id": secondClipID.uuidString,
                "source_time": 3.5,
                "duration": 1.0,
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        stored = try XCTUnwrap(store.project(id: project.id))
        let freezeID = try XCTUnwrap(
            stored.clips.first { $0.kind == .freeze }?.id
        )
        XCTAssertEqual(stored.revision, 4)

        response = try await request(
            host,
            name: "storybird_delete_clip",
            arguments: [
                "project_id": project.id.uuidString,
                "expected_revision": 4,
                "clip_id": freezeID.uuidString,
            ]
        )
        XCTAssertFalse(response.isError, response.text)
        stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertFalse(stored.clips.contains { $0.id == freezeID })
        XCTAssertTrue(stored.clips.contains { $0.id == firstClipID })
        XCTAssertEqual(stored.revision, 5)
    }

    func test_timelineTrackLayout_usesCanonicalEditedClock() throws {
        var project = validVideoProject()
        let originalClipID = try XCTUnwrap(project.clips.first?.id)
        project = try VideoTimelineEditor.split(
            project: project,
            clipID: originalClipID,
            sourceTime: 2
        )
        let firstClipID = project.clips[0].id
        project = try VideoTimelineEditor.setSpeed(
            project: project,
            clipID: firstClipID,
            rate: 2
        )
        project = try DemoEffectEditor.insertTitle(
            in: project,
            after: nil,
            duration: 1
        )

        let spans = TimelineTrackLayout.clipSpans(in: project)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(spans[0].end, 2, accuracy: 0.001)
        XCTAssertEqual(spans[1].start, 2, accuracy: 0.001)
        XCTAssertEqual(spans[1].end, 5, accuracy: 0.001)
    }

    func test_externalControl_applySuggestion_matchesNativeSuggestionEditor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        var project = validVideoProject()
        project.suggestions = ClickSuggestionGenerator.generate(
            for: project
        )
        try repository.saveProjects([project])
        let suggestionID = try XCTUnwrap(project.suggestions.first?.id)
        let expected = try ClickSuggestionGenerator.apply(
            suggestionID,
            to: project
        )
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let arguments = try JSONSerialization.data(
            withJSONObject: [
                "project_id": project.id.uuidString,
                "expected_revision": 0,
                "suggestion_id": suggestionID.uuidString,
            ]
        )

        let response = await host.handle(
            StorybirdControlRequest(
                name: "storybird_apply_suggestion",
                argumentsJSON: arguments
            )
        )
        guard !response.isError else {
            return XCTFail(response.text)
        }
        let stored = try XCTUnwrap(store.project(id: project.id))

        // Child clip UUIDs are allocated independently by each invocation.
        // Canonicalize only those IDs, preserving every property and relationship.
        var normalizedJSON = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        for (native, actual) in zip(expected.clips, stored.clips) {
            normalizedJSON = normalizedJSON.replacingOccurrences(of: native.id.uuidString, with: actual.id.uuidString)
        }
        let normalized = try JSONDecoder().decode(DemoProject.self, from: Data(normalizedJSON.utf8))
        XCTAssertEqual(stored.clips, normalized.clips)
        XCTAssertEqual(stored.effects, normalized.effects)
        XCTAssertEqual(stored.suggestions, normalized.suggestions)
        XCTAssertEqual(stored.revision, 1)
    }

    private func schemaObject(
        for toolName: String
    ) throws -> [String: Any] {
        let tool = try XCTUnwrap(
            StorybirdMCPService.toolDefinitions.first {
                $0.name == toolName
            }
        )
        let data = try JSONEncoder().encode(tool.inputSchema)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func propertyNames(
        for toolName: String
    ) throws -> Set<String> {
        let schema = try schemaObject(for: toolName)
        let properties = try XCTUnwrap(
            schema["properties"] as? [String: Any]
        )
        return Set(properties.keys)
    }

    private func validVideoProject() -> DemoProject {
        var click = TimedPointerClick(
            time: 1,
            x: 0.5,
            y: 0.5,
            caption: "Click"
        )
        click.cueSubtitle.text = "Continue"
        return DemoProject(
            name: "Video",
            recording: VideoRecordingAsset(
                filename: "recording.mp4",
                duration: 5,
                width: 640,
                height: 480
            ),
            clicks: [click]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func request(
        _ host: StorybirdExternalControlHost,
        name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        let data = try JSONSerialization.data(
            withJSONObject: arguments,
            options: [.sortedKeys]
        )
        return await host.handle(
            StorybirdControlRequest(
                name: name,
                argumentsJSON: data
            )
        )
    }
}
