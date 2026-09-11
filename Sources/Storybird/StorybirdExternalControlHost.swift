import Foundation
import StorybirdCore
import StorybirdMCPKit

@MainActor
final class StorybirdExternalControlHost {
    private enum ExportState: String, Codable {
        case validating
        case rendering
        case completed
        case failed
        case cancelled
    }

    private struct ExportJob: Codable {
        let id: UUID
        var state: ExportState
        var progress: Double
        var outputPath: String?
        var error: String?
    }

    private struct ProjectMutationResponse<Value: Encodable>: Encodable {
        let revision: Int
        let targetID: UUID
        let value: Value

        private enum CodingKeys: String, CodingKey {
            case revision
            case targetID = "target_id"
            case value
        }
    }

    private struct TimelineMutationResponse: Encodable {
        let revision: Int
        let clipIDs: [UUID]

        private enum CodingKeys: String, CodingKey {
            case revision
            case clipIDs = "clip_ids"
        }
    }

    private unowned let store: AppStore
    private let recordingSession: StorybirdControlSession
    private var server: StorybirdLocalControlServer?
    private var exportJobs: [UUID: ExportJob] = [:]
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var recordingStorageOperationID: UUID?
    private var isStartingRecording = false

    init(
        store: AppStore,
        recordingSession: StorybirdControlSession = StorybirdControlSession()
    ) {
        self.store = store
        self.recordingSession = recordingSession
    }

    /// Starts the authenticated gateway once the Storybird app is running.
    func start() {
        guard server == nil else { return }
        let server = StorybirdLocalControlServer(
            rootURL: store.repository.sharedRootURL
        ) { [weak self] request in
            guard let self else {
                return StorybirdControlResponse(
                    text: "Storybird control is unavailable.",
                    isError: true
                )
            }
            return await self.handle(request)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            store.errorMessage =
                "Storybird could not start local MCP control: \(error.localizedDescription)"
        }
    }

    /// Dispatches authenticated commands through existing app models and services.
    func handle(
        _ request: StorybirdControlRequest
    ) async -> StorybirdControlResponse {
        let operation = store.beginStorageOperation(.externalCommand)
        defer { store.endStorageOperation(operation) }
        do {
            let arguments = try Self.arguments(from: request.argumentsJSON)
            switch request.name {
            case "storybird_import_video", "storybird_import_audio":
                return try Self.jsonResponse(store.mediaImports.start(
                    kind: request.name == "storybird_import_video" ? .video : .audio,
                    path: Self.string("path", in: arguments),
                    projectID: request.name == "storybird_import_audio"
                        ? Self.uuid("project_id", in: arguments) : nil,
                    key: Self.string("idempotency_key", in: arguments)
                ))
            case "storybird_get_import":
                return try Self.jsonResponse(store.mediaImports.get(id: Self.uuid("job_id", in: arguments)))
            case "storybird_cancel_import":
                return try Self.jsonResponse(store.mediaImports.cancel(id: Self.uuid("job_id", in: arguments)))
            case "storybird_list_sources",
                 "storybird_start_session",
                 "storybird_observe",
                 "storybird_move_pointer",
                 "storybird_click",
                 "storybird_scroll",
                 "storybird_abort_session",
                 "storybird_stop_session":
                return try await handleRecordingCommand(
                    request.name,
                    arguments: arguments
                )
            case "storybird_list_audio_assets",
                 "storybird_place_audio_asset",
                 "storybird_update_audio_layer",
                 "storybird_split_audio_layer",
                 "storybird_duplicate_audio_layer",
                 "storybird_delete_audio_layer",
                 "storybird_set_source_audio",
                 "storybird_render_audio_preview":
                return try await handleAudioCommand(request.name, arguments: arguments)
            case "storybird_get_edit_context",
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
                 "storybird_list_projects",
                 "storybird_duplicate_project",
                 "storybird_get_project",
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
                 "storybird_preview_project",
                 "storybird_render_preview",
                 "storybird_delete_project":
                return try await handleProjectCommand(
                    request.name,
                    arguments: arguments
                )
            case "storybird_start_export",
                 "storybird_get_export",
                 "storybird_cancel_export",
                 "storybird_export_project":
                return try await handleExportCommand(
                    request.name,
                    arguments: arguments
                )
            case "storybird_start_narration_draft",
                 "storybird_list_narration_drafts",
                 "storybird_get_narration_draft",
                 "storybird_cancel_narration_draft",
                 "storybird_place_narration_draft",
                 "storybird_list_voice_profiles",
                 "storybird_generate_narration",
                 "storybird_update_narration",
                 "storybird_delete_narration":
                return try await handleVoiceCommand(
                    request.name,
                    arguments: arguments
                )
            default:
                return StorybirdControlResponse(
                    text: "Unknown Storybird tool: \(request.name)",
                    isError: true
                )
            }
        } catch {
            return StorybirdControlResponse(
                text: error.localizedDescription,
                isError: true
            )
        }
    }

    /// Handles reusable audio without exposing microphone or file-picker actions.
    /// The store remains the single writer and validates revision before edits.
    private func handleAudioCommand(_ name: String, arguments: [String: Any]) async throws -> StorybirdControlResponse {
        let project = try project(from: arguments)
        let a = AgentEditArguments(values: arguments)
        if name == "storybird_list_audio_assets" {
            struct AssetResponse: Encodable {
                let asset: ProjectAudioAsset
                let summary: AudioFileSummary
            }
            var assets: [AssetResponse] = []
            try VideoProjectValidator.validate(project)
            for asset in project.availableAudioAssets {
                let url = store.repository.assetURL(projectID: project.id, filename: asset.filename)
                guard url.resolvingSymlinksInPath().deletingLastPathComponent()
                    == store.repository.assetsDirectory(projectID: project.id).resolvingSymlinksInPath() else {
                    throw VideoProjectValidationError.invalidAssetFilename
                }
                let summary = try await Task.detached { try ProjectAudioFiles.inspect(url) }.value
                assets.append(AssetResponse(asset: asset, summary: summary))
            }
            return try Self.jsonResponse(assets)
        }
        if name == "storybird_render_audio_preview" {
            guard let recording = project.recording else { throw RecordingStoreError.videoNotFound }
            let result = try await AudioPreviewRenderer.render(
                project: project,
                sourceURL: store.repository.assetURL(projectID: project.id, filename: recording.filename),
                startTime: a.number("start_time"), duration: a.number("duration")
            )
            return try Self.jsonResponse(result)
        }
        let revision = try Self.requiredInt("expected_revision", in: arguments)
        guard revision == project.revision else { throw RecordingStoreError.revisionConflict(project.revision) }
        let edited = try AgentAudioEditor.apply(name, arguments: arguments, to: project)
        return try Self.jsonResponse(store.saveProject(edited, expectedRevision: revision))
    }

    /// Uses only existing user-created profiles while keeping registration,
    /// microphone capture, model preparation, and profile deletion out of MCP.
    private func handleVoiceCommand(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        let values = AgentEditArguments(values: arguments)
        switch name {
        case "storybird_start_narration_draft":
            return try Self.jsonResponse(store.startNarrationDraft(
                projectID: Self.uuid("project_id", in: arguments),
                voiceProfileID: Self.uuid("voice_profile_id", in: arguments),
                text: Self.string("text", in: arguments),
                language: values.text("language", default: "korean")
            ))
        case "storybird_list_narration_drafts":
            return try Self.jsonResponse(project(from: arguments).narrationDrafts)
        case "storybird_get_narration_draft":
            let project = try project(from: arguments)
            let id = try Self.uuid("draft_id", in: arguments)
            return try Self.jsonResponse(Self.unwrap(project.narrationDrafts.first { $0.id == id }, message: "Draft not found."))
        case "storybird_cancel_narration_draft":
            let projectID = try Self.uuid("project_id", in: arguments)
            let id = try Self.uuid("draft_id", in: arguments)
            try store.cancelNarrationDraft(projectID: projectID, draftID: id)
            return try Self.jsonResponse(project(from: arguments).narrationDrafts)
        case "storybird_place_narration_draft":
            return try Self.jsonResponse(await store.placeNarrationDraft(
                projectID: Self.uuid("project_id", in: arguments),
                draftID: Self.uuid("draft_id", in: arguments),
                expectedRevision: Self.requiredInt("expected_revision", in: arguments),
                startTime: values.number("start_time"),
                timingMode: Self.timingMode(arguments) ?? .project
            ))
        case "storybird_list_voice_profiles":
            return try Self.jsonResponse(
                store.voiceProfiles.map(ExternalVoiceProfile.init)
            )
        case "storybird_generate_narration":
            let projectID = try Self.uuid("project_id", in: arguments)
            let revision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            let profileID = try Self.uuid(
                "voice_profile_id",
                in: arguments
            )
            let text = try Self.string("text", in: arguments)
            let startTime = try values.number("start_time")
            let language = try values.text("language", default: "korean")
            let saved = try await store.generateNarration(
                projectID: projectID,
                expectedRevision: revision,
                voiceProfileID: profileID,
                text: text,
                language: language,
                startTime: startTime,
                timingMode: try Self.timingMode(arguments) ?? .project
            )
            return try Self.jsonResponse(saved)
        case "storybird_update_narration":
            let project = try project(from: arguments)
            let expectedRevision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            let id = try Self.uuid("narration_id", in: arguments)
            let saved = try await store.updateNarration(
                projectID: project.id,
                narrationID: id,
                expectedRevision: expectedRevision,
                text: values.has("text") ? values.text("text") : nil,
                language: values.has("language") ? values.text("language") : nil,
                startTime: values.has("start_time") ? values.number("start_time") : nil,
                volume: values.has("volume") ? values.number("volume") : nil,
                timingMode: try Self.timingMode(arguments)
            )
            return try Self.jsonResponse(saved)
        case "storybird_delete_narration":
            let project = try project(from: arguments)
            let expectedRevision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            let id = try Self.uuid("narration_id", in: arguments)
            let saved = try store.deleteNarration(
                projectID: project.id,
                narrationID: id,
                expectedRevision: expectedRevision
            )
            return try Self.jsonResponse(saved)
        default:
            throw StorybirdControlWireError.invalidMessage
        }
    }

    /// Handles the native-consent recording and real pointer command family.
    private func handleRecordingCommand(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        switch name {
        case "storybird_list_sources":
            return try Self.jsonResponse(
                await recordingSession.listSources()
            )
        case "storybird_start_session":
            guard store.canStartScreenRecording else { throw AudioSessionError.busy }
            guard recordingStorageOperationID == nil else {
                throw StorybirdMCPError.sessionAlreadyActive
            }
            let sourceID = try Self.string("source_id", in: arguments)
            let projectName = try Self.string("project_name", in: arguments)
            let sources = try await recordingSession.listSources()
            let source = try Self.unwrap(
                sources.first { $0.id == sourceID },
                message: "The selected source is unavailable."
            )
            guard await store.requestExternalControlApproval(
                title: "Allow Storybird MCP Control?",
                message: "Record “\(source.title)” as local video, share its current frame with the connected MCP client, and allow real pointer movement, clicks, and scrolling?"
            ) else {
                throw StorybirdMCPError.consentRequired
            }
            guard recordingStorageOperationID == nil else {
                throw StorybirdMCPError.sessionAlreadyActive
            }
            guard store.canStartScreenRecording else { throw AudioSessionError.busy }
            let projectID = UUID()
            let target = try store.repository.prepareVideoRecordingURL(
                projectID: projectID
            )
            let operation = store.beginStorageOperation(.recording)
            recordingStorageOperationID = operation
            isStartingRecording = true
            defer { isStartingRecording = false }
            do {
                let frame = try await recordingSession.startSession(
                    sourceID: sourceID,
                    projectID: projectID,
                    projectName: projectName,
                    recordingFilename: target.filename,
                    outputURL: target.url
                )
                return Self.frameResponse(
                    frame,
                    text: "Storybird MCP video recording started."
                )
            } catch {
                try? store.repository.removeProjectAssets(
                    projectID: projectID
                )
                store.endStorageOperation(operation)
                recordingStorageOperationID = nil
                throw error
            }
        case "storybird_observe":
            return Self.frameResponse(
                try await recordingSession.observe(),
                text: "Latest selected-source frame."
            )
        case "storybird_move_pointer":
            return Self.frameResponse(
                try await recordingSession.movePointer(
                    x: try Self.double("x", in: arguments),
                    y: try Self.double("y", in: arguments),
                    durationMilliseconds:
                        Self.int("duration_ms", in: arguments) ?? 250
                ),
                text: "Pointer moved."
            )
        case "storybird_click":
            let button = StorybirdMCPPointerButton(
                rawValue: try Self.string(
                    "button",
                    in: arguments,
                    default: "left"
                )
            )
            let result = try await recordingSession.click(
                x: try Self.double("x", in: arguments),
                y: try Self.double("y", in: arguments),
                button: try Self.unwrap(
                    button,
                    message: "button must be left or right"
                )
            )
            return Self.frameResponse(
                result.frame,
                text: result.observedFreshFrame
                    ? "Click completed."
                    : "Click completed; a fresh follow-up frame was unavailable."
            )
        case "storybird_scroll":
            return Self.frameResponse(
                try await recordingSession.scroll(
                    x: try Self.double("x", in: arguments),
                    y: try Self.double("y", in: arguments),
                    deltaX: try Self.double("delta_x", in: arguments),
                    deltaY: try Self.double("delta_y", in: arguments)
                ),
                text: "Scroll completed."
            )
        case "storybird_abort_session":
            store.cancelExternalControlApproval()
            await recordingSession.abort()
            releaseRecordingStorageOperation()
            return StorybirdControlResponse(
                text: "Storybird MCP session aborted."
            )
        case "storybird_stop_session":
            defer { releaseRecordingStorageOperation() }
            let recording = try await recordingSession.stopSession()
            try store.commitRecordedVideo(
                projectID: recording.projectID,
                name: recording.projectName,
                filename: recording.filename,
                result: recording.result,
                clicks: recording.clicks
            )
            return StorybirdControlResponse(
                text: "Storybird video project completed: \(recording.projectID.uuidString)"
            )
        default:
            throw StorybirdControlWireError.invalidMessage
        }
    }

    private func releaseRecordingStorageOperation() {
        // Abort/Stop may arrive while the capture actor is still opening its
        // source. That start owns the token until it succeeds or cleans up.
        guard !isStartingRecording else { return }
        if let recordingStorageOperationID {
            store.endStorageOperation(recordingStorageOperationID)
            self.recordingStorageOperationID = nil
        }
    }

    /// Handles revision-checked project edits, preview, and confirmed deletion.
    private func handleProjectCommand(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        switch name {
        case "storybird_get_edit_context":
            let project = try project(from: arguments)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let model = try JSONSerialization.jsonObject(with: encoder.encode(project))
            var sceneNumber = 0
            let scenes: [[String: Any]] = VideoTimelineSchedule(project: project).items.compactMap { item in
                guard case let .clip(clip) = item else { return nil }
                sceneNumber += 1
                return ["scene_number": sceneNumber, "clip_id": clip.clip.id.uuidString,
                        "start_time": clip.projectStart, "end_time": clip.projectEnd,
                        "source_start": clip.clip.sourceStart, "source_end": clip.clip.sourceEnd,
                        "kind": clip.clip.kind.rawValue, "playback_rate": clip.clip.playbackRate]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "project": model, "scenes": scenes,
                "guidance": "Scene numbers are one-based clip order, excluding title/CTA cards. Resolve the user's text against these IDs and current text; use expected_revision on edits."
            ], options: [.sortedKeys])
            return StorybirdControlResponse(text: String(decoding: data, as: UTF8.self))
        case "storybird_create_project":
            let id = store.createProject(name: try Self.string("name", in: arguments))
            return try Self.jsonResponse(Self.unwrap(store.project(id: id), message: store.errorMessage ?? "Project creation failed."))
        case "storybird_create_click", "storybird_delete_click", "storybird_delete_subtitle",
             "storybird_create_spotlight", "storybird_create_pan_zoom", "storybird_insert_title",
             "storybird_insert_cta", "storybird_update_effect", "storybird_delete_effect",
             "storybird_update_suggestion", "storybird_apply_suggestion", "storybird_reject_suggestion":
            let project = try project(from: arguments)
            let revision = try Self.requiredInt("expected_revision", in: arguments)
            guard project.revision == revision else { throw RecordingStoreError.revisionConflict(project.revision) }
            let edited = try AgentProjectEditor.apply(name, arguments: arguments, to: project)
            let saved = try store.saveProject(edited, expectedRevision: revision)
            return try Self.jsonResponse(saved)
        case "storybird_list_projects":
            return try Self.jsonResponse(store.projects)
        case "storybird_duplicate_project":
            return try Self.jsonResponse(
                try await store.duplicateProject(
                    projectID: Self.uuid("project_id", in: arguments),
                    expectedRevision: Self.requiredInt("expected_revision", in: arguments),
                    name: arguments["name"] as? String
                )
            )
        case "storybird_get_project":
            return try Self.jsonResponse(
                try project(from: arguments)
            )
        case "storybird_replace_project":
            let projectID = try Self.uuid("project_id", in: arguments)
            let expectedRevision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.userInfo[.strictProjectEdits] = true
            let replacement = try decoder.decode(
                DemoProject.self,
                from: Data(
                    try Self.string(
                        "project_json",
                        in: arguments
                    ).utf8
                )
            )
            guard replacement.id == projectID else {
                throw StorybirdControlWireError.invalidMessage
            }
            return try Self.jsonResponse(
                try store.saveProject(
                    replacement,
                    expectedRevision: expectedRevision
                )
            )
        case "storybird_split_clip":
            let clipID = try Self.uuid("clip_id", in: arguments)
            let sourceTime = try Self.double("source_time", in: arguments)
            return try saveTimelineMutation(arguments) { project in
                let existingIDs = Set(project.clips.map(\.id))
                let edited = try VideoTimelineEditor.split(
                    project: project,
                    clipID: clipID,
                    sourceTime: sourceTime
                )
                let insertedIDs = edited.clips.compactMap {
                    existingIDs.contains($0.id) ? nil : $0.id
                }
                return (edited, [clipID] + insertedIDs)
            }
        case "storybird_trim_clip":
            let clipID = try Self.uuid("clip_id", in: arguments)
            let sourceStart = try Self.double(
                "source_start",
                in: arguments
            )
            let sourceEnd = try Self.double("source_end", in: arguments)
            return try saveTimelineMutation(arguments) { project in
                (
                    try VideoTimelineEditor.trim(
                        project: project,
                        clipID: clipID,
                        sourceStart: sourceStart,
                        sourceEnd: sourceEnd
                    ),
                    [clipID]
                )
            }
        case "storybird_delete_clip":
            let clipID = try Self.uuid("clip_id", in: arguments)
            return try saveTimelineMutation(arguments) { project in
                (
                    try VideoTimelineEditor.delete(
                        project: project,
                        clipID: clipID
                    ),
                    [clipID]
                )
            }
        case "storybird_move_clip":
            let clipID = try Self.uuid("clip_id", in: arguments)
            let destination = try Self.requiredInt(
                "destination",
                in: arguments
            )
            return try saveTimelineMutation(arguments) { project in
                (
                    try VideoTimelineEditor.move(
                        project: project,
                        clipID: clipID,
                        destination: destination
                    ),
                    [clipID]
                )
            }
        case "storybird_set_clip_speed":
            let clipID = try Self.uuid("clip_id", in: arguments)
            let rate = try Self.double("rate", in: arguments)
            return try saveTimelineMutation(arguments) { project in
                (
                    try VideoTimelineEditor.setSpeed(
                        project: project,
                        clipID: clipID,
                        rate: rate
                    ),
                    [clipID]
                )
            }
        case "storybird_insert_freeze":
            let clipID = try Self.uuid("clip_id", in: arguments)
            let sourceTime = try Self.double("source_time", in: arguments)
            let duration = try Self.double("duration", in: arguments)
            return try saveTimelineMutation(arguments) { project in
                let existingIDs = Set(project.clips.map(\.id))
                let edited = try VideoTimelineEditor.insertFreeze(
                    project: project,
                    after: clipID,
                    sourceTime: sourceTime,
                    duration: duration
                )
                let insertedIDs = edited.clips.compactMap {
                    existingIDs.contains($0.id) ? nil : $0.id
                }
                return (edited, insertedIDs)
            }
        case "storybird_undo_project":
            return try Self.jsonResponse(
                try store.undo(
                    projectID: try Self.uuid(
                        "project_id",
                        in: arguments
                    ),
                    expectedRevision: try Self.requiredInt(
                        "expected_revision",
                        in: arguments
                    )
                )
            )
        case "storybird_redo_project":
            return try Self.jsonResponse(
                try store.redo(
                    projectID: try Self.uuid(
                        "project_id",
                        in: arguments
                    ),
                    expectedRevision: try Self.requiredInt(
                        "expected_revision",
                        in: arguments
                    )
                )
            )
        case "storybird_update_project":
            var project = try project(from: arguments)
            let expectedRevision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            if let name = arguments["name"] as? String {
                project.name = name
            }
            if let summary = arguments["summary"] as? String {
                project.summary = summary
            }
            return try Self.jsonResponse(
                try store.saveProject(
                    project,
                    expectedRevision: expectedRevision
                )
            )
        case "storybird_update_click":
            let project = try project(from: arguments)
            let revision = try Self.requiredInt("expected_revision", in: arguments)
            guard project.revision == revision else { throw RecordingStoreError.revisionConflict(project.revision) }
            let id = try Self.uuid("click_id", in: arguments)
            let edited = try AgentProjectEditor.apply(name, arguments: arguments, to: project)
            let saved = try store.saveProject(edited, expectedRevision: revision)
            let click = try Self.unwrap(saved.clicks.first { $0.id == id }, message: "Click not found.")
            return try Self.jsonResponse(ProjectMutationResponse(revision: saved.revision, targetID: id, value: click))
        case "storybird_upsert_subtitle":
            return try upsertSubtitle(arguments)
        case "storybird_preview_project":
            let project = try project(from: arguments)
            store.requestedPreviewProjectID = project.id
            return StorybirdControlResponse(text: "Preview opened.")
        case "storybird_render_preview":
            let project = try project(from: arguments)
            guard let recording = project.recording else {
                throw VideoProjectValidationError.missingRecording
            }
            let projectTime = try AgentEditArguments(values: arguments).number("time")
            let frame = try await LayeredVideoExporter().previewFrame(
                project: project,
                sourceURL: store.repository.assetURL(
                    projectID: project.id,
                    filename: recording.filename
                ),
                projectTime: projectTime
            )
            let metadata = [
                "time": frame.projectTime,
                "visible_layer_ids": visibleLayerIDs(
                    in: project,
                    at: frame.projectTime
                ),
                "incomplete_click_ids": project.clicks
                    .filter { !$0.isComplete }
                    .map { $0.id.uuidString },
            ] as [String: Any]
            return StorybirdControlResponse(
                text: String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: metadata,
                        options: [.sortedKeys]
                    ),
                    as: UTF8.self
                ),
                imageData: frame.pngData
            )
        case "storybird_delete_project":
            let project = try project(from: arguments)
            guard await store.requestExternalControlApproval(
                title: "Delete “\(project.name)”?",
                message: "The MCP client requested permanent deletion of this local demo and its captured assets.",
                destructive: true
            ) else {
                return StorybirdControlResponse(
                    text: "Deletion cancelled.",
                    isError: true
                )
            }
            store.deleteProject(id: project.id)
            return StorybirdControlResponse(text: "Project deleted.")
        default:
            throw StorybirdControlWireError.invalidMessage
        }
    }

    /// Applies one native timeline command and returns its revision and changed clip IDs.
    private func saveTimelineMutation(
        _ arguments: [String: Any],
        edit: (DemoProject) throws -> (DemoProject, [UUID])
    ) throws -> StorybirdControlResponse {
        let current = try project(from: arguments)
        let expectedRevision = try Self.requiredInt(
            "expected_revision",
            in: arguments
        )
        let (edited, changedClipIDs) = try edit(current)
        let saved = try store.saveProject(
            edited,
            expectedRevision: expectedRevision
        )
        return try Self.jsonResponse(
            TimelineMutationResponse(
                revision: saved.revision,
                clipIDs: changedClipIDs
            )
        )
    }

    /// Handles synchronous and job-based MP4 export commands on one state machine.
    private func handleExportCommand(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        switch name {
        case "storybird_start_export":
            let exportID = try store.beginExport()
            do {
                let project = try project(from: arguments)
                try LayeredVideoExporter.validateForExport(project)
                let parent = URL(
                    fileURLWithPath: try Self.string(
                        "parent_directory",
                        in: arguments
                    )
                )
                let jobID = UUID()
                exportJobs[jobID] = ExportJob(
                    id: jobID,
                    state: .validating,
                    progress: 0
                )
                let store = self.store
                exportTasks[jobID] = Task { [weak self, store] in
                    defer {
                        store.endExport(exportID)
                    }
                    guard let self else { return }
                    do {
                        guard let recording = project.recording else {
                            throw VideoProjectValidationError.missingRecording
                        }
                        self.updateExport(jobID) {
                            $0.state = .rendering
                        }
                        let destination = Self.uniqueVideoDestination(
                            projectName: project.name,
                            in: parent
                        )
                        let result = try await LayeredVideoExporter().export(
                            project: project,
                            sourceURL: store.repository.assetURL(
                                projectID: project.id,
                                filename: recording.filename
                            ),
                            destinationURL: destination
                        ) { progress in
                            Task { @MainActor [weak self] in
                                self?.updateExport(jobID) {
                                    $0.progress = progress * 100
                                }
                            }
                        }
                        self.updateExport(jobID) {
                            $0.state = .completed
                            $0.progress = 100
                            $0.outputPath = result.path
                        }
                    } catch is CancellationError {
                        self.updateExport(jobID) {
                            $0.state = .cancelled
                        }
                    } catch {
                        self.updateExport(jobID) {
                            $0.state = .failed
                            $0.error = error.localizedDescription
                        }
                    }
                    self.exportTasks[jobID] = nil
                }
                return try Self.jsonResponse(exportJobs[jobID]!)
            } catch {
                store.endExport(exportID)
                throw error
            }
        case "storybird_get_export":
            let id = try Self.uuid("job_id", in: arguments)
            return try Self.jsonResponse(
                try Self.unwrap(
                    exportJobs[id],
                    message: "The export job does not exist."
                )
            )
        case "storybird_cancel_export":
            let id = try Self.uuid("job_id", in: arguments)
            guard let job = exportJobs[id] else {
                throw StorybirdControlWireError.invalidMessage
            }
            if job.state == .validating || job.state == .rendering {
                exportTasks[id]?.cancel()
            }
            return try Self.jsonResponse(exportJobs[id]!)
        case "storybird_export_project":
            let exportID = try store.beginExport()
            defer {
                store.endExport(exportID)
            }
            let project = try project(from: arguments)
            let parent = URL(
                fileURLWithPath: try Self.string(
                    "parent_directory",
                    in: arguments
                )
            )
            guard let recording = project.recording else {
                throw VideoProjectValidationError.missingRecording
            }
            let destination = Self.uniqueVideoDestination(
                projectName: project.name,
                in: parent
            )
            let sourceURL = store.repository.assetURL(
                projectID: project.id,
                filename: recording.filename
            )
            let result = try await LayeredVideoExporter().export(
                project: project,
                sourceURL: sourceURL,
                destinationURL: destination
            )
            return StorybirdControlResponse(text: result.path)
        default:
            throw StorybirdControlWireError.invalidMessage
        }
    }

    /// Mutates one known export job without permitting terminal-state resurrection.
    private func updateExport(
        _ id: UUID,
        _ update: (inout ExportJob) -> Void
    ) {
        guard var job = exportJobs[id],
              job.state != .completed,
              job.state != .failed,
              job.state != .cancelled
        else {
            return
        }
        update(&job)
        exportJobs[id] = job
    }

    private func visibleLayerIDs(
        in project: DemoProject,
        at time: Double
    ) -> [String] {
        VideoOverlayPresentation.visibleLayerIDs(
            in: project,
            at: time
        ).map(\.uuidString)
    }

    /// Adds or updates one bounded subtitle through the app-owned project writer.
    private func upsertSubtitle(
        _ arguments: [String: Any]
    ) throws -> StorybirdControlResponse {
        var project = try project(from: arguments)
        let expectedRevision = try Self.requiredInt(
            "expected_revision",
            in: arguments
        )
        guard project.recording != nil else {
            throw VideoProjectValidationError.missingRecording
        }
        var subtitle: TimedSubtitle
        if arguments["subtitle_id"] != nil {
            let id = try Self.uuid("subtitle_id", in: arguments)
            subtitle = try Self.unwrap(
                project.subtitles.first { $0.id == id },
                message: "The subtitle layer does not exist."
            )
        } else {
            subtitle = TimedSubtitle(startTime: 0, endTime: 0)
        }
        // Assign after initialization so malformed IPC values are rejected,
        // rather than normalized by the models' UI convenience initializers.
        subtitle.startTime = try Self.double("start_time", in: arguments)
        subtitle.endTime = try Self.double("end_time", in: arguments)
        if let mode = try Self.timingMode(arguments) {
            subtitle.sceneAnchor = mode == .scene ? try SceneTiming.anchor(at: subtitle.startTime, in: project) : nil
        } else if subtitle.sceneAnchor != nil {
            subtitle.sceneAnchor = try SceneTiming.anchor(at: subtitle.startTime, in: project)
        }
        if arguments["text"] != nil {
            subtitle.text = try Self.string("text", in: arguments)
        }
        if arguments["position"] != nil {
            subtitle.position = try Self.unwrap(
                SubtitlePosition(
                    rawValue: try Self.string("position", in: arguments)
                ),
                message: "Subtitle position must be top or bottom."
            )
        }
        if arguments["background_hex"] != nil {
            subtitle.style.backgroundHex = try Self.string(
                "background_hex", in: arguments
            )
        }
        if arguments["background_opacity"] != nil {
            let opacity = try Self.double("background_opacity", in: arguments)
            guard opacity.isFinite, (0...1).contains(opacity) else {
                throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
            }
            subtitle.style.backgroundOpacity = opacity
        }
        if arguments["foreground_hex"] != nil {
            subtitle.style.foregroundHex = try Self.string(
                "foreground_hex", in: arguments
            )
        }
        if arguments["font_size"] != nil {
            let size = try Self.double("font_size", in: arguments)
            guard size.isFinite, size >= 1 else {
                throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
            }
            subtitle.style.fontSize = size
        }
        guard subtitle.startTime.isFinite,
              subtitle.endTime.isFinite,
              subtitle.startTime >= 0,
              subtitle.startTime < subtitle.endTime,
              subtitle.endTime <= project.timelineDuration
        else {
            throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
        }
        if let index = project.subtitles.firstIndex(
            where: { $0.id == subtitle.id }
        ) {
            project.subtitles[index] = subtitle
        } else {
            project.subtitles.append(subtitle)
        }
        let saved = try store.saveProject(
            project,
            expectedRevision: expectedRevision
        )
        let savedSubtitle = try Self.unwrap(
            saved.subtitles.first { $0.id == subtitle.id },
            message: "Subtitle update failed."
        )
        return try Self.jsonResponse(
            ProjectMutationResponse(
                revision: saved.revision,
                targetID: savedSubtitle.id,
                value: savedSubtitle
            )
        )
    }

    /// Reads an explicit timing choice without changing omitted legacy defaults.
    private static func timingMode(_ arguments: [String: Any]) throws -> LayerTimingMode? {
        guard arguments["timing_mode"] != nil else { return nil }
        return try unwrap(
            LayerTimingMode(rawValue: string("timing_mode", in: arguments)),
            message: "timing_mode must be project or scene."
        )
    }

    /// Resolves a project UUID from command arguments.
    private func project(
        from arguments: [String: Any]
    ) throws -> DemoProject {
        let id = try Self.uuid("project_id", in: arguments)
        return try Self.unwrap(
            store.project(id: id),
            message: "The project does not exist."
        )
    }

    /// Decodes MCP JSON arguments without linking the app to MCP wire types.
    private static func arguments(from data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Encodes local models into a text response.
    private static func jsonResponse<T: Encodable>(
        _ value: T
    ) throws -> StorybirdControlResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return StorybirdControlResponse(
            text: String(decoding: try encoder.encode(value), as: UTF8.self)
        )
    }

    /// Returns image bytes separately from human-readable MCP text.
    private static func frameResponse(
        _ frame: StorybirdMCPFrame,
        text: String
    ) -> StorybirdControlResponse {
        StorybirdControlResponse(
            text: "\(text) \(frame.width)×\(frame.height).",
            imageData: frame.pngData
        )
    }

    /// Reads one required or defaulted string without coercing other IPC JSON types.
    private static func string(
        _ key: String,
        in values: [String: Any],
        default defaultValue: String? = nil
    ) throws -> String {
        if let value = values[key] as? String { return value }
        if let defaultValue { return defaultValue }
        throw StorybirdControlWireError.invalidMessage
    }

    /// Reads one finite-number candidate for downstream coordinate or timeline validation.
    private static func double(
        _ key: String,
        in values: [String: Any]
    ) throws -> Double {
        guard let number = values[key] as? NSNumber else {
            throw StorybirdControlWireError.invalidMessage
        }
        return number.doubleValue
    }

    /// Reads one optional integer used only for bounded pointer movement pacing.
    private static func int(
        _ key: String,
        in values: [String: Any]
    ) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }

    /// Rejects booleans and fractional revisions before optimistic concurrency
    /// checks, rather than coercing them into another valid revision.
    private static func requiredInt(
        _ key: String,
        in values: [String: Any]
    ) throws -> Int {
        let value = try AgentEditArguments(values: values).number(key)
        guard value >= 0, value.rounded() == value, value < Double(Int.max) else {
            throw StorybirdControlWireError.invalidMessage
        }
        return Int(value)
    }

    /// Rejects malformed project and layer identifiers before app-owned mutation.
    private static func uuid(
        _ key: String,
        in values: [String: Any]
    ) throws -> UUID {
        guard let raw = values[key] as? String,
              let id = UUID(uuidString: raw)
        else {
            throw StorybirdControlWireError.invalidMessage
        }
        return id
    }

    /// Converts a missing validated lookup into an explicit control response error.
    private static func unwrap<T>(
        _ value: T?,
        message: String
    ) throws -> T {
        guard let value else {
            throw NSError(
                domain: "StorybirdControl",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return value
    }

    /// Chooses a unique local MP4 name without overwriting an earlier export.
    private static func uniqueVideoDestination(
        projectName: String,
        in parent: URL
    ) -> URL {
        let allowed = CharacterSet.alphanumerics
        let slug = String(
            projectName.lowercased().unicodeScalars.map {
                allowed.contains($0) ? Character(String($0)) : "-"
            }
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        )
        let base = slug.isEmpty ? "storybird-video" : slug
        var destination = parent.appendingPathComponent("\(base).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = parent.appendingPathComponent(
                "\(base)-\(suffix).mp4"
            )
            suffix += 1
        }
        return destination
    }
}

private struct ExternalVoiceProfile: Encodable {
    let id: UUID
    let name: String
    let language: String

    /// Reduces the MCP listing to selection metadata so reference filenames,
    /// exact transcripts, and consent records remain inside Storybird.
    init(_ profile: VoiceProfile) {
        id = profile.id
        name = profile.name
        language = profile.language
    }
}
