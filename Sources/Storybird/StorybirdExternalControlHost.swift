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
    private let recordingSession = StorybirdControlSession()
    private var server: StorybirdLocalControlServer?
    private var exportJobs: [UUID: ExportJob] = [:]
    private var exportTasks: [UUID: Task<Void, Never>] = [:]

    init(store: AppStore) {
        self.store = store
    }

    /// Starts the authenticated gateway once the Storybird app is running.
    func start() {
        guard server == nil else { return }
        let server = StorybirdLocalControlServer(
            rootURL: store.repository.rootURL
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
        do {
            let arguments = try Self.arguments(from: request.argumentsJSON)
            switch request.name {
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
            case "storybird_list_projects",
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
            let projectID = UUID()
            let target = try store.repository.prepareVideoRecordingURL(
                projectID: projectID
            )
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
            return StorybirdControlResponse(
                text: "Storybird MCP session aborted."
            )
        case "storybird_stop_session":
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

    /// Handles revision-checked project edits, preview, and confirmed deletion.
    private func handleProjectCommand(
        _ name: String,
        arguments: [String: Any]
    ) async throws -> StorybirdControlResponse {
        switch name {
        case "storybird_list_projects":
            return try Self.jsonResponse(store.projects)
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
            var project = try project(from: arguments)
            let expectedRevision = try Self.requiredInt(
                "expected_revision",
                in: arguments
            )
            let clickID = try Self.uuid("click_id", in: arguments)
            let index = try Self.unwrap(
                project.clicks.firstIndex { $0.id == clickID },
                message: "The click layer does not exist."
            )
            if let caption = arguments["caption"] as? String {
                project.clicks[index].caption = caption
            }
            if let x = (arguments["x"] as? NSNumber)?.doubleValue {
                project.clicks[index].x = x
            }
            if let y = (arguments["y"] as? NSNumber)?.doubleValue {
                project.clicks[index].y = y
            }
            if let hex = arguments["background_hex"] as? String {
                project.clicks[index].captionStyle.backgroundHex = hex
            }
            if let opacity = (arguments["background_opacity"] as? NSNumber)?
                .doubleValue {
                project.clicks[index].captionStyle.backgroundOpacity =
                    opacity
            }
            let saved = try store.saveProject(
                project,
                expectedRevision: expectedRevision
            )
            let savedClick = saved.clicks[index]
            return try Self.jsonResponse(
                ProjectMutationResponse(
                    revision: saved.revision,
                    targetID: savedClick.id,
                    value: savedClick
                )
            )
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
            let projectTime = try Self.double("time", in: arguments)
            let data = try await LayeredVideoExporter().previewPNG(
                project: project,
                sourceURL: store.repository.assetURL(
                    projectID: project.id,
                    filename: recording.filename
                ),
                projectTime: projectTime
            )
            let metadata = [
                "time": projectTime,
                "visible_layer_ids": visibleLayerIDs(
                    in: project,
                    at: projectTime
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
                imageData: data
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
            guard !exportJobs.values.contains(where: {
                $0.state == .validating || $0.state == .rendering
            }) else {
                throw LayeredVideoExportError.exportFailed(
                    "Another export is already active."
                )
            }
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
            exportTasks[jobID] = Task { [weak self] in
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
                        sourceURL: self.store.repository.assetURL(
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
        let subtitleID = (arguments["subtitle_id"] as? String)
            .flatMap(UUID.init(uuidString:))
        let subtitle = TimedSubtitle(
            id: subtitleID ?? UUID(),
            startTime: try Self.double("start_time", in: arguments),
            endTime: try Self.double("end_time", in: arguments),
            text: try Self.string("text", in: arguments, default: ""),
            position: SubtitlePosition(
                rawValue: try Self.string(
                    "position",
                    in: arguments,
                    default: "bottom"
                )
            ) ?? .bottom,
            style: TextOverlayStyle(
                backgroundHex: try Self.string(
                    "background_hex",
                    in: arguments,
                    default: "#11131A"
                ),
                backgroundOpacity: (arguments["background_opacity"] as? NSNumber)?
                    .doubleValue ?? 0.72
            )
        )
        guard subtitle.startTime < subtitle.endTime,
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

    /// Reads one required integer used for optimistic project revision checks.
    private static func requiredInt(
        _ key: String,
        in values: [String: Any]
    ) throws -> Int {
        guard let value = int(key, in: values) else {
            throw StorybirdControlWireError.invalidMessage
        }
        return value
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
