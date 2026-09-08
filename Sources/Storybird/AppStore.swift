import Combine
import AVFoundation
import Foundation
import StorybirdCore

enum VoiceRuntimeState: Equatable {
    case notPrepared
    case preparing
    case ready
    case failed(String)
}

enum VoiceReferenceSource {
    case importedFile
    case microphone
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [DemoProject] = []
    @Published var selectedProjectID: UUID?
    @Published var errorMessage: String?
    @Published var permissionPrompt: RecordingPermissionPrompt?
    @Published var externalControlPrompt: ExternalControlPrompt?
    @Published var requestedPreviewProjectID: UUID?
    @Published private(set) var isExportActive = false
    @Published private(set) var voiceProfiles: [VoiceProfile] = []
    @Published private(set) var voiceRuntimeState: VoiceRuntimeState = .notPrepared

    let repository: ProjectRepository
    private var externalControlContinuation:
        CheckedContinuation<Bool, Never>?
    private var undoHistory: [UUID: [DemoProject]] = [:]
    private var redoHistory: [UUID: [DemoProject]] = [:]
    private var activeExportID: UUID?
    private let voiceServiceOverride: (any VoiceSynthesisProviding)?
    private lazy var voiceService: any VoiceSynthesisProviding =
        voiceServiceOverride ?? VoiceSynthesisService(
            rootURL: repository.rootURL
        )

    init(
        repository: ProjectRepository? = nil,
        voiceService: (any VoiceSynthesisProviding)? = nil
    ) {
        voiceServiceOverride = voiceService
        let resolvedRepository: ProjectRepository
        do {
            resolvedRepository = try repository ?? .live()
        } catch {
            let fallback = ProjectRepository(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Storybird", isDirectory: true)
            )
            self.repository = fallback
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
            return
        }

        self.repository = resolvedRepository
        do {
            projects = try resolvedRepository.loadProjects()
            voiceProfiles = try resolvedRepository.loadVoiceProfiles()
            selectedProjectID = projects.first?.id
        } catch {
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
        }
    }

    /// Prepares the user-approved local MLX runtime and model without changing
    /// projects or voice profiles if installation or download fails.
    func prepareVoiceRuntime() async {
        voiceRuntimeState = .preparing
        do {
            try await voiceService.prepare()
            voiceRuntimeState = .ready
        } catch {
            voiceRuntimeState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Restores the visible runtime state from local executable and model-cache
    /// markers without contacting the model provider.
    func refreshVoiceRuntimeState() async {
        voiceRuntimeState = await voiceService.prepared()
            ? .ready
            : .notPrepared
    }

    /// Imports one user-authorized MP3/WAV into the local voice library only
    /// after consent, transcript, duration, and readable-audio validation pass.
    func importVoiceProfile(
        name: String,
        sourceURL: URL,
        transcript: String,
        language: String = "korean",
        source: VoiceReferenceSource = .importedFile,
        consentConfirmed: Bool
    ) async throws -> VoiceProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard !trimmedName.isEmpty,
              !trimmedTranscript.isEmpty,
              consentConfirmed,
              ["mp3", "wav"].contains(fileExtension)
        else {
            throw VoiceProfileError.invalidInput
        }
        let duration = try await Self.audioDuration(at: sourceURL)
        guard source != .microphone
                || duration >= VoiceRecordingRequirements.minimumDuration
        else {
            throw VoiceProfileError.referenceTooShort
        }
        let profileID = UUID()
        let prepared = try repository.prepareVoiceReferenceURL(
            profileID: profileID,
            fileExtension: fileExtension
        )
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
            try FileManager.default.copyItem(
                at: sourceURL,
                to: prepared.url
            )
            let profile = VoiceProfile(
                id: profileID,
                name: trimmedName,
                referenceFilename: prepared.filename,
                referenceText: trimmedTranscript,
                language: language,
                consentConfirmed: true
            )
            var updated = voiceProfiles
            updated.append(profile)
            try repository.saveVoiceProfiles(updated)
            voiceProfiles = updated
            return profile
        } catch {
            try? repository.removeVoiceProfileAssets(profileID: profileID)
            throw error
        }
    }

    /// Removes sensitive reference audio and transcript while leaving every
    /// project-owned generated narration asset unchanged.
    func deleteVoiceProfile(id: UUID) throws {
        guard voiceProfiles.contains(where: { $0.id == id }) else {
            throw VoiceProfileError.profileNotFound
        }
        let updated = voiceProfiles.filter { $0.id != id }
        try repository.saveVoiceProfiles(updated)
        try repository.removeVoiceProfileAssets(profileID: id)
        voiceProfiles = updated
    }

    /// Generates one complete WAV before revision-checked project publication,
    /// deleting the unreferenced asset on synthesis or conflict failure.
    func generateNarration(
        projectID: UUID,
        expectedRevision: Int,
        voiceProfileID: UUID,
        text: String,
        language: String,
        startTime: Double
    ) async throws -> DemoProject {
        guard let project = project(id: projectID) else {
            throw RecordingStoreError.projectNotFound
        }
        guard let profile = voiceProfiles.first(
            where: { $0.id == voiceProfileID }
        ), profile.consentConfirmed else {
            throw VoiceProfileError.profileNotFound
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceProfileError.invalidInput
        }
        let prepared = try repository.prepareNarrationURL(
            projectID: projectID
        )
        do {
            let result = try await voiceService.generate(
                text: trimmed,
                referenceAudioURL: repository.voiceReferenceURL(
                    profileID: profile.id,
                    filename: profile.referenceFilename
                ),
                referenceText: profile.referenceText,
                language: language,
                outputURL: prepared.url
            )
            try Task.checkCancellation()
            let duration = try await Self.validatedNarrationDuration(
                at: prepared.url,
                reportedDuration: result.duration
            )
            try Task.checkCancellation()
            var updated = project
            updated.narrations.append(
                NarrationClip(
                    voiceProfileID: profile.id,
                    filename: prepared.filename,
                    text: trimmed,
                    language: language,
                    startTime: startTime,
                    duration: duration
                )
            )
            updated.narrations.sort { $0.startTime < $1.startTime }
            return try saveProject(
                updated,
                expectedRevision: expectedRevision
            )
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }

    /// Regenerates only the selected narration when its text changes and applies
    /// optional timing or volume edits in the same revision-checked publication.
    func updateNarration(
        projectID: UUID,
        narrationID: UUID,
        expectedRevision: Int,
        text: String? = nil,
        language: String? = nil,
        startTime: Double? = nil,
        volume: Double? = nil
    ) async throws -> DemoProject {
        guard var project = project(id: projectID),
              let index = project.narrations.firstIndex(
                  where: { $0.id == narrationID }
              )
        else {
            throw RecordingStoreError.projectNotFound
        }
        if text == nil, language != nil {
            throw VoiceProfileError.invalidInput
        }
        var replacementURL: URL?
        let previousFilename = project.narrations[index].filename
        do {
            if let text {
                let trimmed = text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty,
                      let profile = voiceProfiles.first(where: {
                          $0.id == project.narrations[index].voiceProfileID
                              && $0.consentConfirmed
                      })
                else {
                    throw VoiceProfileError.invalidInput
                }
                let prepared = try repository.prepareNarrationURL(
                    projectID: projectID
                )
                replacementURL = prepared.url
                let resolvedLanguage = language
                    ?? project.narrations[index].language
                let result = try await voiceService.generate(
                    text: trimmed,
                    referenceAudioURL: repository.voiceReferenceURL(
                        profileID: profile.id,
                        filename: profile.referenceFilename
                    ),
                    referenceText: profile.referenceText,
                    language: resolvedLanguage,
                    outputURL: prepared.url
                )
                try Task.checkCancellation()
                let duration = try await Self.validatedNarrationDuration(
                    at: prepared.url,
                    reportedDuration: result.duration
                )
                try Task.checkCancellation()
                project.narrations[index].filename = prepared.filename
                project.narrations[index].text = trimmed
                project.narrations[index].language = resolvedLanguage
                project.narrations[index].duration = duration
            }
            if let startTime {
                project.narrations[index].startTime = startTime
            }
            if let volume {
                project.narrations[index].volume = volume
            }
            project.narrations.sort { $0.startTime < $1.startTime }
            let saved = try saveProject(
                project,
                expectedRevision: expectedRevision
            )
            if replacementURL != nil {
                try? FileManager.default.removeItem(
                    at: repository.assetURL(
                        projectID: projectID,
                        filename: previousFilename
                    )
                )
            }
            return saved
        } catch {
            if let replacementURL {
                try? FileManager.default.removeItem(at: replacementURL)
            }
            throw error
        }
    }

    /// Removes one narration through revision validation and deletes its WAV only
    /// after the project no longer references the asset.
    func deleteNarration(
        projectID: UUID,
        narrationID: UUID,
        expectedRevision: Int
    ) throws -> DemoProject {
        guard var project = project(id: projectID),
              let index = project.narrations.firstIndex(
                  where: { $0.id == narrationID }
              )
        else {
            throw RecordingStoreError.projectNotFound
        }
        let narration = project.narrations.remove(at: index)
        let saved = try saveProject(
            project,
            expectedRevision: expectedRevision
        )
        try? FileManager.default.removeItem(
            at: repository.assetURL(
                projectID: projectID,
                filename: narration.filename
            )
        )
        return saved
    }

    /// Rejects non-audio and empty references before any profile directory or
    /// index entry is created.
    private static func audioDuration(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).first != nil
        else {
            throw VoiceProfileError.invalidInput
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw VoiceProfileError.invalidInput
        }
        return duration
    }

    /// Independently probes a generated WAV and rejects missing, corrupt, empty,
    /// or materially inconsistent output before a project can reference it.
    private static func validatedNarrationDuration(
        at url: URL,
        reportedDuration: Double
    ) async throws -> Double {
        guard reportedDuration.isFinite, reportedDuration > 0 else {
            throw VoiceSynthesisError.invalidResponse
        }
        let measured = try await audioDuration(at: url)
        let tolerance = max(0.1, measured * 0.02)
        guard abs(measured - reportedDuration) <= tolerance else {
            throw VoiceSynthesisError.invalidResponse
        }
        return measured
    }

    var selectedProject: DemoProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Resolves one project without exposing mutable library storage to callers.
    func project(id: UUID) -> DemoProject? {
        projects.first { $0.id == id }
    }

    /// Creates an empty local placeholder that remains separate from future recordings.
    func createProject(name: String = "Untitled recording") -> UUID {
        let project = DemoProject(name: name)
        projects.insert(project, at: 0)
        selectedProjectID = project.id
        persist()
        return project.id
    }

    /// Validates video timing and coordinates before atomically replacing project metadata.
    func replaceProject(_ project: DemoProject) {
        do {
            try saveProject(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persists one validated UI edit against the current in-memory revision.
    func saveProject(_ project: DemoProject) throws {
        guard let stored = self.project(id: project.id) else {
            throw RecordingStoreError.projectNotFound
        }
        _ = try saveProject(project, expectedRevision: stored.revision)
    }

    /// Rejects stale edits and advances revision exactly once for one atomic project change.
    @discardableResult
    func saveProject(
        _ project: DemoProject,
        expectedRevision: Int,
        recordUndo: Bool = true
    ) throws -> DemoProject {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw RecordingStoreError.projectNotFound
        }
        let current = projects[index]
        guard current.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(current.revision)
        }
        var comparable = project
        comparable.revision = current.revision
        comparable.updatedAt = current.updatedAt
        guard current != comparable else {
            return current
        }
        var updated = comparable
        updated.revision = current.revision + 1
        updated.updatedAt = Date()
        try Self.validateTransition(from: current, to: updated)
        if updated.recording != nil {
            try VideoProjectValidator.validate(updated)
        }
        var updatedProjects = projects
        updatedProjects[index] = updated
        try repository.saveProjects(updatedProjects)
        if recordUndo {
            undoHistory[project.id, default: []].append(current)
            redoHistory[project.id] = []
        }
        projects = updatedProjects
        return updated
    }

    /// Preserves terminal suggestion states while allowing applied or rejected
    /// metadata cleanup only after the referenced Click Cue has been removed.
    private static func validateTransition(
        from current: DemoProject,
        to updated: DemoProject
    ) throws {
        let updatedByID = Dictionary(
            uniqueKeysWithValues: updated.suggestions.map { ($0.id, $0) }
        )
        let updatedClickIDs = Set(updated.clicks.map(\.id))
        for suggestion in current.suggestions {
            switch suggestion.state {
            case .pending:
                continue
            case .applied:
                if let next = updatedByID[suggestion.id] {
                    guard next.state == .applied else {
                        throw RecordingStoreError.invalidSuggestionTransition
                    }
                } else if updatedClickIDs.contains(suggestion.clickID) {
                    throw RecordingStoreError.invalidSuggestionTransition
                }
            case .rejected:
                if let next = updatedByID[suggestion.id] {
                    guard next.state == .rejected else {
                        throw RecordingStoreError.invalidSuggestionTransition
                    }
                } else if updatedClickIDs.contains(suggestion.clickID) {
                    throw RecordingStoreError.invalidSuggestionTransition
                }
            }
        }
    }

    /// Restores one complete project edit while keeping revision monotonic.
    func undo(
        projectID: UUID,
        expectedRevision: Int? = nil
    ) throws -> DemoProject {
        guard let current = project(id: projectID) else {
            throw RecordingStoreError.projectNotFound
        }
        if let expectedRevision,
           current.revision != expectedRevision {
            throw RecordingStoreError.revisionConflict(current.revision)
        }
        guard var history = undoHistory[projectID],
              let previous = history.popLast()
        else {
            throw RecordingStoreError.noUndo
        }
        undoHistory[projectID] = history
        redoHistory[projectID, default: []].append(current)
        var replacement = previous
        replacement.revision = current.revision
        return try saveProject(
            replacement,
            expectedRevision: current.revision,
            recordUndo: false
        )
    }

    /// Reapplies one previously undone project edit.
    func redo(
        projectID: UUID,
        expectedRevision: Int? = nil
    ) throws -> DemoProject {
        guard let current = project(id: projectID) else {
            throw RecordingStoreError.projectNotFound
        }
        if let expectedRevision,
           current.revision != expectedRevision {
            throw RecordingStoreError.revisionConflict(current.revision)
        }
        guard var history = redoHistory[projectID],
              let next = history.popLast()
        else {
            throw RecordingStoreError.noRedo
        }
        redoHistory[projectID] = history
        undoHistory[projectID, default: []].append(current)
        var replacement = next
        replacement.revision = current.revision
        return try saveProject(
            replacement,
            expectedRevision: current.revision,
            recordUndo: false
        )
    }

    /// Publishes a completed recording only after its MP4 and timed clicks validate together.
    func commitRecordedVideo(
        projectID: UUID,
        name: String,
        filename: String,
        result: ScreenVideoRecordingResult,
        clicks: [TimedPointerClick]
    ) throws {
        do {
            let videoURL = repository.assetURL(
                projectID: projectID,
                filename: filename
            )
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw RecordingStoreError.videoNotFound
            }
            var project = DemoProject(
                id: projectID,
                name: name,
                recording: VideoRecordingAsset(
                    filename: filename,
                    duration: result.duration,
                    width: result.width,
                    height: result.height
                ),
                clicks: clicks.map { $0.bounded(to: result.duration) }
            )
            project.suggestions = ClickSuggestionGenerator.generate(for: project)
            project.updatedAt = Date()
            try publishNewVideoProject(project)
        } catch {
            try? repository.removeProjectAssets(projectID: projectID)
            throw error
        }
    }

    /// Creates a new project only after a user-selected movie has been copied and
    /// validated as a complete project-owned source asset.
    func importVideo(from sourceURL: URL) async throws -> UUID {
        let fileExtension = try LocalVideoImporter.supportedFileExtension(
            for: sourceURL
        )
        let projectID = UUID()
        let prepared = try repository.prepareImportedVideoURL(
            projectID: projectID,
            fileExtension: fileExtension
        )
        do {
            let metadata = try await LocalVideoImporter.copyAndInspect(
                sourceURL: sourceURL,
                destinationURL: prepared.url
            )
            let sourceName = sourceURL.deletingPathExtension()
                .lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let project = DemoProject(
                id: projectID,
                name: sourceName.isEmpty ? "Imported video" : sourceName,
                recording: VideoRecordingAsset(
                    filename: prepared.filename,
                    duration: metadata.duration,
                    width: metadata.width,
                    height: metadata.height,
                    mediaStartTime: metadata.mediaStartTime
                )
            )
            try publishNewVideoProject(project)
            return projectID
        } catch {
            try? repository.removeProjectAssets(projectID: projectID)
            throw error
        }
    }

    /// Validates and atomically publishes one completed source-video project so
    /// recording and import share the same save-before-selection ordering.
    private func publishNewVideoProject(
        _ project: DemoProject
    ) throws {
        try VideoProjectValidator.validate(project)
        var updatedProjects = projects
        updatedProjects.insert(project, at: 0)
        try repository.saveProjects(updatedProjects)
        projects = updatedProjects
        selectedProjectID = project.id
    }

    /// Acquires the app-wide export lease shared by UI and MCP entry points so a
    /// second encoder cannot start while the current export remains active.
    func beginExport() throws -> UUID {
        guard activeExportID == nil else {
            throw RecordingStoreError.exportAlreadyActive
        }
        let id = UUID()
        activeExportID = id
        isExportActive = true
        return id
    }

    /// Releases only the matching export lease, preventing a stale completion from
    /// clearing a newer export's app-wide active state.
    func endExport(_ id: UUID) {
        guard activeExportID == id else { return }
        activeExportID = nil
        isExportActive = false
    }

    /// Requests a native decision before an external control session or deletion.
    func requestExternalControlApproval(
        title: String,
        message: String,
        destructive: Bool = false
    ) async -> Bool {
        guard externalControlContinuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            externalControlContinuation = continuation
            externalControlPrompt = ExternalControlPrompt(
                title: title,
                message: message,
                destructive: destructive
            )
        }
    }

    /// Resolves the pending native external-control decision exactly once.
    func resolveExternalControlApproval(_ allowed: Bool) {
        let continuation = externalControlContinuation
        externalControlContinuation = nil
        externalControlPrompt = nil
        continuation?.resume(returning: allowed)
    }

    /// Invalidates a stale native prompt when its requesting MCP transport disappears.
    func cancelExternalControlApproval() {
        resolveExternalControlApproval(false)
    }

    /// Removes one project and its owned recording before persisting the remaining library.
    func deleteProject(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        do {
            try repository.removeProjectAssets(projectID: id)
        } catch {
            errorMessage = "Some project files could not be removed: \(error.localizedDescription)"
        }

        projects.remove(at: index)
        if selectedProjectID == id {
            selectedProjectID = projects.first?.id
        }
        persist()
    }

    /// Persists the full in-memory library through atomic JSON replacement.
    private func persist() {
        do {
            try repository.saveProjects(projects)
        } catch {
            errorMessage = "Changes could not be saved: \(error.localizedDescription)"
        }
    }
}

enum RecordingStoreError: LocalizedError, Equatable {
    case projectNotFound
    case videoNotFound
    case revisionConflict(Int)
    case noUndo
    case noRedo
    case invalidSuggestionTransition
    case exportAlreadyActive

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "The recording project no longer exists."
        case .videoNotFound:
            return "The completed recording file is missing."
        case let .revisionConflict(current):
            return "The project changed. Reload revision \(current) before editing."
        case .noUndo:
            return "There is no project edit to undo."
        case .noRedo:
            return "There is no project edit to redo."
        case .invalidSuggestionTransition:
            return "Applied or rejected edit suggestions cannot return to pending."
        case .exportAlreadyActive:
            return "Another export is already active."
        }
    }
}

enum VoiceProfileError: LocalizedError {
    case invalidInput
    case referenceTooShort
    case profileNotFound
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Provide a valid MP3/WAV, matching transcript, name, and voice-use consent."
        case .referenceTooShort:
            return "The guided microphone recording must contain at least 10 seconds of speech."
        case .profileNotFound:
            return "The selected voice profile no longer exists."
        case .microphonePermissionDenied:
            return "Microphone access is required only for the guided voice-profile recording."
        }
    }
}

struct RecordingPermissionPrompt: Identifiable {
    enum Kind: String {
        case screenRecording
        case inputMonitoring
    }

    let kind: Kind
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .screenRecording:
            return "Allow Screen Recording"
        case .inputMonitoring:
            return "Allow Input Monitoring"
        }
    }

    var message: String {
        switch kind {
        case .screenRecording:
            return "Storybird needs Screen Recording access to record the selected display or window as video."
        case .inputMonitoring:
            return "Storybird needs Input Monitoring access to observe mouse clicks during a recording session. Keyboard input is not recorded."
        }
    }

    var settingsURL: URL? {
        let pane: String
        switch kind {
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
        case .inputMonitoring:
            pane = "Privacy_ListenEvent"
        }
        return URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        )
    }
}
