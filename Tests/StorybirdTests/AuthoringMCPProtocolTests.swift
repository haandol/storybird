@preconcurrency import AVFoundation
import Foundation
import ImageIO
import MCP
import StorybirdCore
@testable import Storybird
@testable import StorybirdMCPKit
import XCTest

@MainActor
final class AuthoringMCPProtocolTests: XCTestCase {
    /// Checks initialization and actual wire discovery against the editing contract;
    /// an unadvertised tool must fail before it reaches the app transport.
    func test_protocolDiscovery_exposesAuthoringSchemasAndRejectsUnknownRouting() async throws {
        try await withClient { client, _, _, _, probe, initialization in
            XCTAssertEqual(initialization.serverInfo.title, "Storybird Video Production")
            let instructions = try XCTUnwrap(initialization.instructions)
            for phrase in ["storybird_get_edit_context", "revision", "native approval",
                           "does not require an active screen-control session", "microphone"] {
                XCTAssertTrue(instructions.contains(phrase), phrase)
            }
            let tools = try await client.listTools().tools
            XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
            let requiredFields: [String: [String]] = [
                "storybird_trim_clip": ["clip_id", "source_start", "source_end"],
                "storybird_create_click": ["time", "x", "y"],
                "storybird_update_click": ["click_id"],
                "storybird_upsert_subtitle": ["start_time", "end_time"],
                "storybird_create_spotlight": ["start_time", "end_time", "x", "y", "width", "height"],
                "storybird_update_effect": ["effect_id"],
                "storybird_replace_project": ["project_json"],
                "storybird_undo_project": [],
                "storybird_redo_project": [],
            ]
            for (name, fields) in requiredFields {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let schema = try schema(tool)
                let required = Set(try XCTUnwrap(schema["required"] as? [String]))
                XCTAssertEqual(required, Set(fields + ["project_id", "expected_revision"]), name)
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false, name)
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let revision = try XCTUnwrap(properties["expected_revision"] as? [String: Any])
                XCTAssertEqual(revision["type"] as? String, "integer", name)
                XCTAssertEqual(revision["minimum"] as? Double, 0, name)
                XCTAssertEqual(tool.annotations.destructiveHint, false, name)
            }
            for name in ["storybird_create_click", "storybird_update_click"] {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let properties = try XCTUnwrap(schema(tool)["properties"] as? [String: Any])
                for field in ["x", "y", "description_x", "description_y", "indicator_opacity",
                              "description_background_opacity", "subtitle_background_opacity"] {
                    let value = try XCTUnwrap(properties[field] as? [String: Any])
                    XCTAssertEqual(value["minimum"] as? Double, 0, "\(name).\(field)")
                    XCTAssertEqual(value["maximum"] as? Double, 1, "\(name).\(field)")
                }
                for field in ["description_font_size", "subtitle_font_size"] {
                    let value = try XCTUnwrap(properties[field] as? [String: Any])
                    XCTAssertEqual(value["minimum"] as? Double, 1, "\(name).\(field) must match the validator")
                }
            }
            for name in ["storybird_get_edit_context", "storybird_get_project", "storybird_list_projects",
                         "storybird_render_preview", "storybird_get_export"] {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                XCTAssertEqual(tool.annotations.readOnlyHint, true, name)
                let properties = try XCTUnwrap(schema(tool)["properties"] as? [String: Any])
                XCTAssertNil(properties["expected_revision"], name)
            }
            for name in ["storybird_create_project", "storybird_start_export", "storybird_import_video",
                         "storybird_import_audio", "storybird_get_import", "storybird_cancel_import"] {
                XCTAssertNotNil(tools.first { $0.name == name }, name)
            }
            let before = await probe.calls
            for name in ["storybird_not_a_tool", "storybird_import_voice_profile", "storybird_record_microphone"] {
                XCTAssertFalse(tools.contains { $0.name == name })
                let result = try await client.callTool(name: name, arguments: [:])
                XCTAssertEqual(result.isError, true, name)
            }
            let after = await probe.calls
            XCTAssertEqual(after, before, "Unadvertised names must never reach app IPC.")
        }
    }

    /// A closed advertised argument object must reject typos before app IPC,
    /// returning only an error while preserving valid companion fields and history.
    func test_protocolClosedSchemas_unknownArgumentsRejectEntireRequest() async throws {
        let names = [
            "storybird_update_click", "storybird_create_click", "storybird_trim_clip",
            "storybird_upsert_subtitle", "storybird_create_spotlight", "storybird_update_effect",
            "storybird_replace_project", "storybird_get_edit_context",
        ]
        for name in names {
            try await withClient { client, store, initial, source, probe, _ in
                let projectID = Value.string(initial.id.uuidString)
                let cueProject: DemoProject = try await call(client, "storybird_create_click", [
                    "project_id": projectID, "expected_revision": 0,
                    "time": 1, "x": 0.5, "y": 0.5,
                    "description": "Original description", "subtitle": "Original subtitle",
                ])
                let project: DemoProject = try await call(client, "storybird_create_spotlight", [
                    "project_id": projectID, "expected_revision": .int(cueProject.revision),
                    "start_time": 0.5, "end_time": 2, "x": 0.2, "y": 0.2,
                    "width": 0.5, "height": 0.5,
                ])
                var arguments: [String: Value] = [
                    "project_id": projectID, "expected_revision": .int(project.revision),
                ]
                switch name {
                case "storybird_update_click":
                    arguments["click_id"] = .string(project.clicks[0].id.uuidString)
                    arguments["description"] = "Valid text must not publish beside a typo"
                case "storybird_create_click":
                    arguments.merge([
                        "time": 2.5, "x": 0.4, "y": 0.4,
                        "description": "Must not create", "subtitle": "Must not create",
                    ]) { _, new in new }
                case "storybird_trim_clip":
                    arguments.merge([
                        "clip_id": .string(project.clips[0].id.uuidString),
                        "source_start": 0, "source_end": 3.5,
                    ]) { _, new in new }
                case "storybird_upsert_subtitle":
                    arguments.merge([
                        "start_time": 0.5, "end_time": 1.5, "text": "Must not create",
                    ]) { _, new in new }
                case "storybird_create_spotlight":
                    arguments.merge([
                        "start_time": 2.5, "end_time": 3.5, "x": 0.2, "y": 0.2,
                        "width": 0.5, "height": 0.5,
                    ]) { _, new in new }
                case "storybird_update_effect":
                    arguments["effect_id"] = .string(project.effects[0].id.uuidString)
                    arguments["dim_opacity"] = 0.2
                case "storybird_replace_project":
                    var object = try projectObject(project)
                    object["name"] = "Valid name must not publish beside an unknown argument"
                    arguments["project_json"] = .string(String(
                        decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self
                    ))
                default:
                    arguments.removeValue(forKey: "expected_revision")
                }
                let unknown = name.contains("click") ? "description_font_szie" : "unadvertised_argument"
                arguments[unknown] = 42
                let tools = try await client.listTools().tools
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let advertised = try schema(tool)
                XCTAssertEqual(advertised["additionalProperties"] as? Bool, false, name)
                let properties = try XCTUnwrap(advertised["properties"] as? [String: Any])
                XCTAssertNil(properties[unknown], name)
                let before = try XCTUnwrap(store.project(id: project.id))
                let library = store.repository.rootURL.appendingPathComponent("library.json")
                let bytes = try Data(contentsOf: library)
                let sourceBytes = try Data(contentsOf: source)
                let callsBefore = await probe.calls
                let response = try await client.callTool(name: name, arguments: arguments)
                let callsAfter = await probe.calls
                XCTAssertEqual(callsAfter, callsBefore, "\(name): unknown arguments must not reach app IPC")
                if response.isError != true {
                    let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response.content))
                    let wire = try JSONSerialization.data(withJSONObject: [
                        "isError": response.isError as Any? ?? NSNull(), "content": content,
                    ], options: [.sortedKeys])
                    print("UNKNOWN_ARGUMENT_RESPONSE \(name) \(String(decoding: wire, as: UTF8.self))")
                }
                XCTAssertEqual(response.isError, true, "\(name) accepted \(unknown)")
                XCTAssertEqual(response.content.count, 1, "\(name): rejection must be text-only")
                if case let .text(message, _, _) = response.content.first {
                    XCTAssertTrue(message.contains(name), message)
                    XCTAssertTrue(message.contains(unknown), message)
                } else {
                    XCTFail("\(name): rejection must return text without an image")
                }
                XCTAssertEqual(store.project(id: project.id), before, name)
                XCTAssertEqual(store.project(id: project.id)?.revision, before.revision, name)
                XCTAssertEqual(try Data(contentsOf: library), bytes, name)
                XCTAssertEqual(try Data(contentsOf: source), sourceBytes, name)
                if response.isError == true {
                    let undone: DemoProject = try await call(client, "storybird_undo_project", [
                        "project_id": projectID, "expected_revision": .int(before.revision),
                    ])
                    assertContent(undone, equals: cueProject)
                    let redone: DemoProject = try await call(client, "storybird_redo_project", [
                        "project_id": projectID, "expected_revision": .int(undone.revision),
                    ])
                    assertContent(redone, equals: project)
                }
            }
        }
    }

    func test_effectTiming_invalidOwnerRejectsAllNativeAndProtocolProperties() async throws {
        try await withClient { client, store, initial, source, _, _ in
            let projectID = Value.string(initial.id.uuidString)
            let split: AuthoringClipMutation = try await call(client, "storybird_split_clip", [
                "project_id": projectID, "expected_revision": 0,
                "clip_id": .string(initial.clips[0].id.uuidString), "source_time": 2,
            ])
            let wireBefore: DemoProject = try await call(client, "storybird_create_pan_zoom", [
                "project_id": projectID, "expected_revision": .int(split.revision),
                "start_time": 0.5, "end_time": 1.5, "end_x": 0.5, "end_y": 0.5, "end_scale": 1.5,
            ])
            let before = try XCTUnwrap(store.project(id: initial.id))
            assertContent(wireBefore, equals: before)
            let library = store.repository.rootURL.appendingPathComponent("library.json")
            let bytes = try Data(contentsOf: library)
            let sourceBytes = try Data(contentsOf: source)
            for (start, end) in [(1.5, 2.5), (2.0, 1.0), (-1.0, 0.5), (3.5, 4.5)] {
                var native = before
                guard case var .panZoom(effect) = native.effects[0] else {
                    return XCTFail("Expected pan/zoom.")
                }
                effect.startTime = start
                effect.endTime = end
                effect.endScale = 2
                native.effects[0] = .panZoom(effect)
                store.errorMessage = nil
                ProjectWorkspaceView(store: store, projectID: initial.id).projectBinding(for: before).wrappedValue = native
                XCTAssertNotNil(store.errorMessage)
                XCTAssertEqual(store.project(id: initial.id), before)
                let response = try await client.callTool(name: "storybird_update_effect", arguments: [
                    "project_id": projectID, "expected_revision": .int(before.revision),
                    "effect_id": .string(effect.id.uuidString),
                    "start_time": .double(start), "end_time": .double(end), "end_scale": 2,
                ])
                XCTAssertEqual(response.isError, true)
                XCTAssertEqual(store.project(id: initial.id), before)
                XCTAssertEqual(try Data(contentsOf: library), bytes)
                XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            }
            let valid: DemoProject = try await call(client, "storybird_update_effect", [
                "project_id": projectID, "expected_revision": .int(before.revision),
                "effect_id": .string(before.effects[0].id.uuidString),
                "start_time": 0.75, "end_time": 1.75, "end_scale": 2,
            ])
            XCTAssertEqual(valid.revision, before.revision + 1)
            XCTAssertEqual(valid.effects[0].startTime, 0.75)
            XCTAssertEqual(valid.effects[0].endTime, 1.75)
            guard case let .panZoom(effect) = valid.effects[0] else { return XCTFail("Expected pan/zoom.") }
            XCTAssertEqual(effect.endScale, 2)
            let undone: DemoProject = try await call(client, "storybird_undo_project", [
                "project_id": projectID, "expected_revision": .int(valid.revision),
            ])
            assertContent(undone, equals: before)
        }
    }

    /// Runs a coordinate-free UI workflow through SDK calls: resolve IDs, edit
    /// media/layers, inspect PNG output, reject atomic failures, undo and export.
    /// Normalized layer coordinates describe video content, never desktop controls.
    func test_protocolAuthoring_editsPreviewsRejectsAtomicallyAndCompletesExport() async throws {
        try await withClient { client, store, initial, source, probe, _ in
            let sourceBytes = try Data(contentsOf: source)
            let placeholder: DemoProject = try await call(client, "storybird_create_project", [
                "name": "Agent-created placeholder",
            ])
            XCTAssertNil(placeholder.recording)
            XCTAssertEqual(placeholder.revision, 0)
            let empty: AuthoringContext = try await call(client, "storybird_get_edit_context", [
                "project_id": .string(placeholder.id.uuidString),
            ])
            XCTAssertEqual(empty.project, placeholder)
            XCTAssertTrue(empty.scenes.isEmpty)
            let listed: [DemoProject] = try await call(client, "storybird_list_projects", [:])
            XCTAssertEqual(Set(listed.map(\.id)), Set([initial.id, placeholder.id]))

            let projectID = Value.string(initial.id.uuidString)
            var context: AuthoringContext = try await call(client, "storybird_get_edit_context", [
                "project_id": projectID,
            ])
            XCTAssertEqual(context.project.id, initial.id)
            XCTAssertEqual(context.scenes.count, 1)
            XCTAssertEqual(context.scenes[0].scene_number, 1)
            XCTAssertEqual(context.scenes[0].clip_id, initial.clips[0].id)
            let trimmed: AuthoringClipMutation = try await call(client, "storybird_trim_clip", [
                "project_id": projectID, "expected_revision": 0,
                "clip_id": .string(context.scenes[0].clip_id.uuidString),
                "source_start": 0.25, "source_end": 3.75,
            ])
            XCTAssertEqual(trimmed.revision, 1)
            XCTAssertEqual(trimmed.clip_ids, [initial.clips[0].id])
            context = try await call(client, "storybird_get_edit_context", ["project_id": projectID])
            XCTAssertEqual(context.project.revision, trimmed.revision)
            XCTAssertEqual(context.project.timelineDuration, 3.5, accuracy: 0.001)
            XCTAssertEqual(context.scenes[0].source_start, 0.25)
            XCTAssertEqual(context.scenes[0].source_end, 3.75)

            var project: DemoProject = try await call(client, "storybird_create_click", [
                "project_id": projectID, "expected_revision": .int(trimmed.revision),
                "time": 1, "x": 0.5, "y": 0.5,
                "description": "Open the project", "subtitle": "Choose a project",
                "description_background_opacity": 0, "subtitle_background_opacity": 1,
            ])
            XCTAssertEqual(project.revision, 2)
            let originalCue = try XCTUnwrap(project.clicks.first)
            XCTAssertTrue(originalCue.isComplete)
            XCTAssertEqual(originalCue.description.style.backgroundOpacity, 0)
            XCTAssertEqual(originalCue.cueSubtitle.style.backgroundOpacity, 1)
            let editedCue: AuthoringLayerMutation<TimedPointerClick> = try await call(client, "storybird_update_click", [
                "project_id": projectID, "expected_revision": .int(project.revision),
                "click_id": .string(originalCue.id.uuidString), "time": 1.1,
            ])
            XCTAssertEqual(editedCue.revision, 3)
            XCTAssertEqual(editedCue.target_id, originalCue.id)
            XCTAssertEqual(editedCue.value.time, 1.1, accuracy: 0.00001)
            XCTAssertEqual(editedCue.value.sourceTime, 1.35, accuracy: 0.00001)
            XCTAssertEqual(editedCue.value.indicator, originalCue.indicator)
            XCTAssertEqual(editedCue.value.description, originalCue.description)
            XCTAssertEqual(editedCue.value.cueSubtitle, originalCue.cueSubtitle)

            let subtitle: AuthoringLayerMutation<TimedSubtitle> = try await call(client, "storybird_upsert_subtitle", [
                "project_id": projectID, "expected_revision": .int(editedCue.revision),
                "start_time": 0.5, "end_time": 2, "text": "Independent instruction",
                "position": "top", "timing_mode": "scene", "background_opacity": 0,
            ])
            XCTAssertEqual(subtitle.revision, 4)
            XCTAssertEqual(subtitle.target_id, subtitle.value.id)
            XCTAssertNotNil(subtitle.value.sceneAnchor)
            let updatedSubtitle: AuthoringLayerMutation<TimedSubtitle> = try await call(client, "storybird_upsert_subtitle", [
                "project_id": projectID, "expected_revision": .int(subtitle.revision),
                "subtitle_id": .string(subtitle.target_id.uuidString),
                "start_time": 0.5, "end_time": 2.5, "text": "Updated instruction",
                "position": "bottom", "background_opacity": 1, "font_size": 20,
            ])
            XCTAssertEqual(updatedSubtitle.revision, 5)
            XCTAssertEqual(updatedSubtitle.target_id, subtitle.target_id)
            XCTAssertEqual(updatedSubtitle.value.text, "Updated instruction")
            XCTAssertEqual(updatedSubtitle.value.style.backgroundOpacity, 1)
            XCTAssertEqual(updatedSubtitle.value.style.fontSize, 20)
            XCTAssertEqual(updatedSubtitle.value.position, .bottom)

            project = try await call(client, "storybird_create_spotlight", [
                "project_id": projectID, "expected_revision": .int(updatedSubtitle.revision),
                "start_time": 0.5, "end_time": 2.5, "x": 0.2, "y": 0.2,
                "width": 0.5, "height": 0.5, "dim_opacity": 0.3,
            ])
            XCTAssertEqual(project.revision, 6)
            let beforeEffectEdit = project
            let effectID = try XCTUnwrap(project.effects.first?.id)
            project = try await call(client, "storybird_update_effect", [
                "project_id": projectID, "expected_revision": .int(project.revision),
                "effect_id": .string(effectID.uuidString), "dim_opacity": 0.6,
            ])
            XCTAssertEqual(project.revision, 7)
            guard case let .spotlight(effect) = try XCTUnwrap(project.effects.first) else {
                throw AuthoringProtocolError.invalidResponse
            }
            XCTAssertEqual(effect.dimOpacity, 0.6)
            XCTAssertEqual(effect.x, 0.2)
            XCTAssertEqual(effect.endTime, 2.5)
            let current = try XCTUnwrap(store.project(id: initial.id))
            let library = store.repository.rootURL.appendingPathComponent("library.json")
            let libraryBytes = try Data(contentsOf: library)
            let preview = try await client.callTool(name: "storybird_render_preview", arguments: [
                "project_id": projectID, "time": 1.113,
            ])
            XCTAssertNotEqual(preview.isError, true)
            let metadata: AuthoringPreview = try decode(preview.content)
            XCTAssertEqual(metadata.time, 1.1, accuracy: 0.00001)
            XCTAssertEqual(Set(metadata.visible_layer_ids), Set([originalCue.id, subtitle.target_id, effectID]))
            XCTAssertTrue(metadata.incomplete_click_ids.isEmpty)
            XCTAssertEqual(preview.content.count, 2)
            guard case let .image(base64, mime, _, _) = preview.content[1],
                  let png = Data(base64Encoded: base64),
                  let imageSource = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw AuthoringProtocolError.invalidResponse
            }
            XCTAssertEqual(mime, "image/png")
            XCTAssertEqual(image.width, initial.recording?.width)
            XCTAssertEqual(image.height, initial.recording?.height)
            XCTAssertEqual(store.project(id: initial.id), current)
            XCTAssertEqual(try Data(contentsOf: library), libraryBytes)

            let clickArguments: [String: Value] = [
                "project_id": projectID, "expected_revision": .int(current.revision),
                "click_id": .string(originalCue.id.uuidString), "description": "Must not save",
            ]
            for fields: [String: Value] in [
                ["time": 3], ["x": 1.01], ["expected_revision": .int(current.revision - 1)],
                ["expected_revision": true], ["expected_revision": 1.5], ["time": "invalid"],
                ["click_id": .string(UUID().uuidString)],
            ] {
                try await assertRejected(client, "storybird_update_click",
                    clickArguments.merging(fields) { _, new in new }, store: store, expected: current,
                    libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)
            }
            var missingRevision = clickArguments
            missingRevision.removeValue(forKey: "expected_revision")
            try await assertRejected(client, "storybird_update_click", missingRevision,
                store: store, expected: current, libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)
            for time: Value in [-0.01, 3.5, true] {
                try await assertRejected(client, "storybird_render_preview", ["project_id": projectID, "time": time],
                    store: store, expected: current, libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)
            }
            for field in ["backgroundOpacity", "fontSize"] {
                var object = try projectObject(current)
                var clicks = try XCTUnwrap(object["clicks"] as? [[String: Any]])
                var description = try XCTUnwrap(clicks[0]["description"] as? [String: Any])
                var style = try XCTUnwrap(description["style"] as? [String: Any])
                style[field] = field == "fontSize" ? 0.999 : 1.01
                description["style"] = style
                description["text"] = "A valid text edit must not publish"
                clicks[0]["description"] = description
                object["clicks"] = clicks
                try await rejectReplacement(object, client: client, store: store, expected: current,
                    libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)
            }
            var forged = try projectObject(current)
            var recording = try XCTUnwrap(forged["recording"] as? [String: Any])
            recording["filename"] = "different-source.mp4"
            forged["recording"] = recording
            forged["name"] = "Must not change the project"
            try await rejectReplacement(forged, client: client, store: store, expected: current,
                libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)

            let undone: DemoProject = try await call(client, "storybird_undo_project", [
                "project_id": projectID, "expected_revision": .int(current.revision),
            ])
            XCTAssertEqual(undone.revision, current.revision + 1)
            assertContent(undone, equals: beforeEffectEdit)
            let redone: DemoProject = try await call(client, "storybird_redo_project", [
                "project_id": projectID, "expected_revision": .int(undone.revision),
            ])
            XCTAssertEqual(redone.revision, undone.revision + 1)
            assertContent(redone, equals: current)
            let fetched: DemoProject = try await call(client, "storybird_get_project", ["project_id": projectID])
            XCTAssertEqual(fetched, redone)

            let beforeExport = try XCTUnwrap(store.project(id: current.id))
            let beforeExportBytes = try Data(contentsOf: library)
            var job: AuthoringExportJob = try await call(client, "storybird_start_export", [
                "project_id": projectID, "parent_directory": .string(store.repository.rootURL.path),
            ])
            for _ in 0..<1_000 {
                if ["completed", "failed", "cancelled"].contains(job.state) { break }
                try await Task.sleep(for: .milliseconds(10))
                job = try await call(client, "storybird_get_export", ["job_id": .string(job.id.uuidString)])
            }
            XCTAssertEqual(job.state, "completed", job.error ?? "Export did not complete")
            XCTAssertEqual(job.progress, 100)
            let output = try XCTUnwrap(job.outputPath)
            XCTAssertNotEqual(output, source.path)
            let asset = AVURLAsset(url: URL(fileURLWithPath: output))
            let duration = try await asset.load(.duration).seconds
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(duration, 3.5, accuracy: 1.0 / 30)
            XCTAssertEqual(videos.count, 1)
            XCTAssertTrue(audio.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            XCTAssertEqual(store.project(id: current.id), beforeExport)
            XCTAssertEqual(try Data(contentsOf: library), beforeExportBytes)
            XCTAssertNil(store.externalControlPrompt)
            let calls = await probe.calls
            XCTAssertFalse(calls.contains("storybird_start_session"))
            XCTAssertFalse(calls.contains("storybird_preview_project"))
            XCTAssertFalse(calls.contains("storybird_move_pointer"))
        }
    }

    /// Sends a raw serialized replacement through the MCP protocol without
    /// model decoding that could hide malformed values before the app sees them.
    private func rejectReplacement(
        _ object: [String: Any], client: Client, store: AppStore, expected: DemoProject,
        libraryBytes: Data, source: URL, sourceBytes: Data
    ) async throws {
        let json = try JSONSerialization.data(withJSONObject: object)
        try await assertRejected(client, "storybird_replace_project", [
            "project_id": .string(expected.id.uuidString), "expected_revision": .int(expected.revision),
            "project_json": .string(String(decoding: json, as: UTF8.self)),
        ], store: store, expected: expected, libraryBytes: libraryBytes, source: source, sourceBytes: sourceBytes)
    }

    /// Verifies error responses leave the entire project and original media
    /// unchanged; later protocol undo/redo checks the retained history contents.
    private func assertRejected(
        _ client: Client, _ name: String, _ arguments: [String: Value],
        store: AppStore, expected: DemoProject, libraryBytes: Data, source: URL, sourceBytes: Data
    ) async throws {
        let result = try await client.callTool(name: name, arguments: arguments)
        XCTAssertEqual(result.isError, true, "\(name): \(result.content)")
        XCTAssertEqual(result.content.count, 1)
        XCTAssertEqual(store.project(id: expected.id), expected, name)
        XCTAssertEqual(store.project(id: expected.id)?.revision, expected.revision, name)
        XCTAssertEqual(try Data(contentsOf: store.repository.rootURL.appendingPathComponent("library.json")), libraryBytes, name)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, name)
    }

    /// Executes real server handlers and host publication with in-memory MCP
    /// transport; only the IPC socket and pre-existing synthetic source are injected.
    private func withClient(
        _ body: (Client, AppStore, DemoProject, URL, AuthoringIPCProbe, Initialize.Result) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository(rootURL: root)
        let id = UUID()
        let target = try repository.prepareVideoRecordingURL(projectID: id)
        let media = try await TestVideoFactory.makeMovie(at: target.url, includeAudio: false, duration: 4)
        let initial = DemoProject(id: id, name: "Synthetic authoring source", recording: VideoRecordingAsset(
            filename: target.filename, duration: media.duration, width: media.width, height: media.height
        ))
        try repository.saveProjects([initial])
        let store = AppStore(repository: repository)
        let host = StorybirdExternalControlHost(store: store)
        let probe = AuthoringIPCProbe()
        let ipc = StorybirdAppIPCClient(sender: { request in
            await probe.record(request.name)
            return await host.handle(request)
        }, launcher: { throw AuthoringProtocolError.unexpectedLaunch })
        let server = await StorybirdMCPService(client: ipc).makeServer()
        let transport = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transport.server)
        let client = Client(name: "Authoring production protocol test", version: "1")
        do {
            let initialization = try await client.connect(transport: transport.client)
            try await body(client, store, initial, target.url, probe, initialization)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Decodes successful wire content and fails immediately on a tool error,
    /// preventing later assertions from obscuring the failed workflow action.
    private func call<T: Decodable>(
        _ client: Client, _ name: String, _ arguments: [String: Value]
    ) async throws -> T {
        let result = try await client.callTool(name: name, arguments: arguments)
        XCTAssertNotEqual(result.isError, true, "\(name): \(result.content)")
        guard result.isError != true else { throw AuthoringProtocolError.invalidResponse }
        return try decode(result.content)
    }

    /// Reads MCP text content using the production date representation.
    private func decode<T: Decodable>(_ content: [Tool.Content]) throws -> T {
        guard case let .text(text, _, _) = try XCTUnwrap(content.first) else {
            throw AuthoringProtocolError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    /// Examines advertised JSON Schema returned by listTools, not static definitions.
    private func schema(_ tool: Tool) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any])
    }

    /// Preserves the wire project structure for adversarial raw JSON mutation.
    private func projectObject(_ project: DemoProject) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(project)) as? [String: Any])
    }

    /// Undo/redo changes publication metadata but must restore all editable content.
    private func assertContent(_ actual: DemoProject, equals expected: DemoProject) {
        var comparable = actual
        comparable.revision = expected.revision
        comparable.updatedAt = expected.updatedAt
        XCTAssertEqual(comparable, expected)
    }
}

private enum AuthoringProtocolError: Error { case unexpectedLaunch, invalidResponse }
private struct AuthoringClipMutation: Decodable { let revision: Int; let clip_ids: [UUID] }
private struct AuthoringLayerMutation<T: Decodable>: Decodable { let revision: Int; let target_id: UUID; let value: T }
private struct AuthoringPreview: Decodable { let time: Double; let visible_layer_ids: [UUID]; let incomplete_click_ids: [UUID] }
private struct AuthoringExportJob: Decodable {
    let id: UUID; let state: String; let progress: Double; let outputPath: String?; let error: String?
}
private struct AuthoringContext: Decodable {
    let project: DemoProject
    let scenes: [Scene]
    struct Scene: Decodable {
        let scene_number: Int; let clip_id: UUID; let source_start: Double; let source_end: Double
    }
}
private actor AuthoringIPCProbe {
    private(set) var calls: [String] = []
    /// Records app-bound names so discovery tests can detect forbidden routing.
    func record(_ name: String) { calls.append(name) }
}
