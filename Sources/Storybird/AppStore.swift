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

    @Published private(set) var repository: ProjectRepository
    @Published private(set) var selectedStorageRootURL: URL?
    @Published private(set) var storageErrorMessage: String?
    @Published private var storageOperations: [UUID: StorageOperation] = [:]
    private let defaultRepository: ProjectRepository
    private let storagePreferences: StorybirdStoragePreferences?
    private var externalControlContinuation:
        CheckedContinuation<Bool, Never>?
    private var undoHistory: [UUID: [DemoProject]] = [:]
    private var redoHistory: [UUID: [DemoProject]] = [:]
    private var activeExportID: UUID?
    private var narrationTasks: [UUID: Task<Void, Never>] = [:]
    lazy var mediaImports = MediaImportController(store: self)
    private let voiceServiceOverride: (any VoiceSynthesisProviding)?
    private lazy var voiceService: any VoiceSynthesisProviding =
        voiceServiceOverride ?? VoiceSynthesisService(
            rootURL: repository.sharedRootURL
        )

    init(
        repository: ProjectRepository? = nil,
        voiceService: (any VoiceSynthesisProviding)? = nil,
        storagePreferences: StorybirdStoragePreferences? = nil
    ) {
        voiceServiceOverride = voiceService
        let preferences = storagePreferences
            ?? (repository == nil ? StorybirdStoragePreferences() : nil)
        self.storagePreferences = preferences
        let selectedRoot = preferences?.selectedRootURL
        selectedStorageRootURL = selectedRoot
        let resolvedRepository: ProjectRepository
        do {
            resolvedRepository = try repository ?? .live()
        } catch {
            let defaultRoot = (try? ProjectRepository.defaultRootURL())
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Documents/Storybird", isDirectory: true)
            let sharedRoot = (try? ProjectRepository.sharedRootURL())
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Storybird", isDirectory: true)
            defaultRepository = ProjectRepository(
                rootURL: defaultRoot,
                sharedRootURL: sharedRoot,
                unavailableReason: error.localizedDescription
            )
            self.repository = ProjectRepository(
                rootURL: selectedRoot ?? defaultRoot,
                sharedRootURL: sharedRoot,
                unavailableReason: error.localizedDescription
            )
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
            storageErrorMessage = errorMessage
            return
        }

        defaultRepository = resolvedRepository
        let activeRepository = selectedRoot.map {
            ProjectRepository(
                rootURL: $0,
                sharedRootURL: resolvedRepository.sharedRootURL,
                requiresExistingRoot: true
            )
        } ?? resolvedRepository
        self.repository = activeRepository
        do {
            projects = try selectedStorageRootURL == nil
                ? activeRepository.loadProjects()
                : activeRepository.validatedProjectsForSelection()
            selectedProjectID = projects.first?.id
            projects = try Self.recoverNarrationDrafts(projects, repository: activeRepository)
        } catch {
            projects = []
            self.repository = ProjectRepository(
                rootURL: activeRepository.rootURL,
                sharedRootURL: activeRepository.sharedRootURL,
                requiresExistingRoot: true,
                unavailableReason: error.localizedDescription
            )
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
            storageErrorMessage = errorMessage
        }
        do {
            voiceProfiles = try resolvedRepository.loadVoiceProfiles()
        } catch {
            errorMessage = "Storybird could not open its voice profiles: \(error.localizedDescription)"
        }
    }

    var storageChangeDisabledReason: String? {
        if isExportActive {
            return "Wait for the video export to finish before changing the folder."
        }
        if let operation = storageOperations.values.sorted(
            by: { $0.rawValue < $1.rawValue }
        ).first {
            return "Finish \(operation.rawValue) before changing the folder."
        }
        if externalControlPrompt != nil {
            return "Resolve the pending MCP approval before changing the folder."
        }
        return nil
    }

    /// Tokens keep overlapping asynchronous jobs from releasing each other's
    /// folder lock. Every job holds its token until commit or cleanup finishes.
    func beginStorageOperation(_ operation: StorageOperation) -> UUID {
        let id = UUID()
        storageOperations[id] = operation
        return id
    }

    func endStorageOperation(_ id: UUID) {
        storageOperations.removeValue(forKey: id)
    }

    var canStartScreenRecording: Bool {
        !storageOperations.values.contains(.microphone)
    }

    /// Reserves microphone input before permission awaits. Profile and project
    /// recording share this lease, excluding screen capture and other microphones.
    func beginMicrophoneOperation() throws -> UUID {
        guard !storageOperations.values.contains(.recording),
              !storageOperations.values.contains(.microphone) else {
            throw AudioSessionError.busy
        }
        return beginStorageOperation(.microphone)
    }

    /// Publishes a fully validated library and its preference in one main-actor
    /// turn. Failure leaves the old repository, selection, and undo history intact.
    @discardableResult
    func chooseStorageFolder(_ url: URL?) -> Bool {
        do {
            if let reason = storageChangeDisabledReason {
                throw RepositoryError.storageUnavailable(reason)
            }
            let root = (url ?? defaultRepository.rootURL)
                .standardizedFileURL.resolvingSymlinksInPath()
            let defaultRoot = defaultRepository.rootURL
                .standardizedFileURL.resolvingSymlinksInPath()
            let candidate = ProjectRepository(
                rootURL: root,
                sharedRootURL: defaultRepository.sharedRootURL,
                requiresExistingRoot: true
            )
            // The native picker creates custom directories. Only the app-owned
            // default may be created here when explicitly restoring it.
            if root == defaultRoot,
               !FileManager.default.fileExists(atPath: root.path) {
                try defaultRepository.prepare()
            }
            let loaded = try Self.recoverNarrationDrafts(
                candidate.validatedProjectsForSelection(), repository: candidate
            )
            let selectedRoot = root == defaultRoot ? nil : root
            storagePreferences?.save(selectedRoot)
            repository = candidate
            projects = loaded
            selectedProjectID = loaded.first?.id
            selectedStorageRootURL = selectedRoot
            undoHistory.removeAll()
            redoHistory.removeAll()
            requestedPreviewProjectID = nil
            storageErrorMessage = nil
            return true
        } catch {
            storageErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Prepares the user-approved local MLX runtime and model without changing
    /// projects or voice profiles if installation or download fails.
    func prepareVoiceRuntime() async {
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
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
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
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

    /// Changes only a profile's display name, publishing to observers after
    /// atomic persistence succeeds so failed writes retain the previous name.
    func renameVoiceProfile(id: UUID, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VoiceProfileError.invalidName }
        guard let index = voiceProfiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceProfileError.profileNotFound
        }
        guard voiceProfiles[index].name != trimmedName else { return }
        var updated = voiceProfiles
        updated[index].name = trimmedName
        try repository.saveVoiceProfiles(updated)
        voiceProfiles = updated
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
        startTime: Double,
        timingMode: LayerTimingMode = .project
    ) async throws -> DemoProject {
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
        guard let project = project(id: projectID) else {
            throw RecordingStoreError.projectNotFound
        }
        guard project.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(project.revision)
        }
        let anchor = timingMode == .scene ? try SceneTiming.anchor(at: startTime, in: project) : nil
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
                    duration: duration,
                    sceneAnchor: anchor
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

    /// Imports a native-selected or MCP-supplied sound into immutable project
    /// storage. Reserved IDs allow restart recovery; registration leaves revision
    /// and undo intact and survives subsequent placement failure.
    func importProjectAudio(
        projectID: UUID, sourceURL: URL, name: String? = nil,
        origin: ProjectAudioAsset.Origin = .imported,
        assetID: UUID = UUID(),
        didDecodeFrames: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> ProjectAudioAsset {
        guard project(id: projectID) != nil else { throw RecordingStoreError.projectNotFound }
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
        let prepared = try repository.prepareNarrationURL(projectID: projectID, assetID: assetID)
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let worker = Task.detached {
                try ProjectAudioFiles.importFile(from: sourceURL, to: prepared.url, didDecodeFrames: didDecodeFrames)
            }
            let summary = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
                throw RecordingStoreError.projectNotFound
            }
            let asset = ProjectAudioAsset(
                id: assetID,
                filename: prepared.filename,
                name: name ?? sourceURL.deletingPathExtension().lastPathComponent,
                duration: summary.duration, origin: origin
            )
            guard !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentEditError.invalidField("name")
            }
            var updated = projects
            updated[index].audioAssets.append(asset)
            try repository.saveProjects(updated)
            projects = updated
            return asset
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }

    /// Publishes a reusable audio placement through the same revision and undo
    /// boundary as every other timeline edit.
    func placeAudioAsset(
        projectID: UUID, assetID: UUID, expectedRevision: Int, startTime: Double,
        sourceStart: Double = 0, duration: Double? = nil, timingMode: LayerTimingMode = .project
    ) throws -> DemoProject {
        guard let project = project(id: projectID) else { throw RecordingStoreError.projectNotFound }
        let edited = try AudioLayerEditor.place(
            assetID: assetID, in: project, startTime: startTime, sourceStart: sourceStart,
            duration: duration, timingMode: timingMode
        )
        return try saveProject(edited, expectedRevision: expectedRevision)
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
        volume: Double? = nil,
        timingMode: LayerTimingMode? = nil
    ) async throws -> DemoProject {
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
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
        guard project.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(project.revision)
        }
        if timingMode != nil || startTime != nil {
            let mode = timingMode ?? (project.narrations[index].sceneAnchor == nil ? .project : .scene)
            project.narrations[index].sceneAnchor = mode == .scene
                ? try SceneTiming.anchor(at: startTime ?? project.narrations[index].startTime, in: project) : nil
        }
        var replacementURL: URL?
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
                project.narrations[index].assetID = UUID()
                project.narrations[index].sourceStart = 0
                project.narrations[index].sourceDuration = duration
                project.narrations[index].fadeEnvelope = nil
                if project.narrations[index].name == project.narrations[index].text {
                    project.narrations[index].name = trimmed
                }
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
            // Previous complete WAVs remain available to this project’s undo history.
            return saved
        } catch {
            if let replacementURL {
                try? FileManager.default.removeItem(at: replacementURL)
            }
            throw error
        }
    }

    /// Removes the layer through revision validation while retaining its WAV for
    /// undo. Project deletion removes all generated assets together.
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
        project.narrations.remove(at: index)
        return try saveProject(project, expectedRevision: expectedRevision)
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
        do {
            var updated = projects
            updated.insert(project, at: 0)
            try repository.saveProjects(updated)
            projects = updated
            selectedProjectID = project.id
        } catch {
            errorMessage = "The project could not be saved: \(error.localizedDescription)"
        }
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

    /// Rejects stale edits and incomplete new narration assets before atomic publication.
    /// A successful change advances revision once; failure leaves index and undo intact.
    @discardableResult
    func saveProject(
        _ project: DemoProject,
        expectedRevision: Int,
        recordUndo: Bool = true,
        placingDraftID: UUID? = nil
    ) throws -> DemoProject {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw RecordingStoreError.projectNotFound
        }
        let current = projects[index]
        guard project.recording == current.recording else {
            throw VideoProjectValidationError.invalidRecording
        }
        guard current.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(current.revision)
        }
        // Legacy screenshot graphs are inventory-only. Even a header rename
        // would re-encode their index as the current video project format.
        guard current.recording != nil || (current.steps.isEmpty && current.events.isEmpty) else {
            throw VideoProjectValidationError.missingRecording
        }
        var comparable = project
        comparable.narrationDrafts = current.narrationDrafts
        comparable.audioAssets = current.audioAssets
        // History is an already validated snapshot. Reinterpreting restoration
        // as a source replacement would erase the original split-fade envelope.
        if recordUndo {
            for index in comparable.narrations.indices {
                if let old = current.narrations.first(where: { $0.id == comparable.narrations[index].id }) {
                    comparable.narrations[index] = AudioLayerEditor.reconcileFade(from: old, to: comparable.narrations[index])
                }
            }
        }
        for narration in comparable.narrations {
            if let draft = current.narrationDrafts.first(where: { $0.filename == narration.filename }),
               draft.state != .placed, draft.id != placingDraftID {
                throw NarrationDraftError.notReady
            }
        }
        if let placingDraftID {
            guard let draftIndex = comparable.narrationDrafts.firstIndex(where: {
                $0.id == placingDraftID && $0.state == .ready
            }), let narration = comparable.narrations.first(where: { $0.id == placingDraftID }),
                narration.filename == comparable.narrationDrafts[draftIndex].filename,
                narration.duration == comparable.narrationDrafts[draftIndex].duration
            else { throw NarrationDraftError.notReady }
            comparable.narrationDrafts[draftIndex].state = .placed
        }
        comparable.revision = current.revision
        comparable.updatedAt = current.updatedAt
        // The JSON wire format uses whole seconds. Preserve stored precision
        // when a round trip still identifies the same creation second.
        if comparable.createdAt.timeIntervalSince1970.rounded(.down)
            == current.createdAt.timeIntervalSince1970.rounded(.down) {
            comparable.createdAt = current.createdAt
        }
        guard current != comparable else {
            return current
        }
        var updated = comparable
        // Retain complete sounds after layer deletion and across undo/redo.
        for asset in (current.availableAudioAssets + comparable.availableAudioAssets)
        where !updated.audioAssets.contains(where: { $0.filename == asset.filename }) {
            updated.audioAssets.append(asset)
        }
        var outputOnly = comparable
        outputOnly.suggestions = current.suggestions
        let suggestionMetadataOnly = outputOnly == current
            && comparable.suggestions.allSatisfy { $0.state != .applied || current.suggestions.contains($0) }
        updated.revision = current.revision + (suggestionMetadataOnly ? 0 : 1)
        updated.updatedAt = suggestionMetadataOnly ? current.updatedAt : Date()
        if recordUndo {
            try Self.validateTransition(from: current, to: updated)
        }
        if updated.recording != nil {
            try VideoProjectValidator.validate(updated)
        }
        for narration in updated.narrations
        where !current.narrations.contains(where: {
            $0.filename == narration.filename && $0.sourceDuration == narration.sourceDuration
        }) {
            try validateNarrationForPublication(narration, projectID: updated.id)
        }
        var updatedProjects = projects
        updatedProjects[index] = updated
        try repository.saveProjects(updatedProjects)
        if recordUndo && !suggestionMetadataOnly {
            undoHistory[project.id, default: []].append(current)
            redoHistory[project.id] = []
        }
        projects = updatedProjects
        return updated
    }

    /// Reads newly referenced audio before the synchronous commit so full replacement
    /// cannot bypass synthesis checks. Existing media and unchanged timing edits avoid
    /// repeated decoding; undo can restore a retained, complete project-owned WAV.
    private func validateNarrationForPublication(
        _ narration: NarrationClip,
        projectID: UUID
    ) throws {
        let url = repository.assetURL(projectID: projectID, filename: narration.filename)
        let directory = repository.assetsDirectory(projectID: projectID)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == directory,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw VoiceSynthesisError.invalidResponse
        }
        let audio = try AVAudioFile(forReading: url)
        let measured = Double(audio.length) / audio.processingFormat.sampleRate
        guard measured.isFinite, measured > 0,
              abs(measured - narration.sourceDuration) <= max(0.1, measured * 0.02),
              narration.sourceStart + narration.duration <= measured + 0.000001,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096)
        else {
            throw VoiceSynthesisError.invalidResponse
        }
        var decodedFrames: AVAudioFramePosition = 0
        while decodedFrames < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else {
                throw VoiceSynthesisError.invalidResponse
            }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// Saves draft metadata without an edit revision; placement uses saveProject
    /// instead so the playable layer and consumed state commit in one replacement.
    func saveNarrationDraft(_ draft: NarrationDraft, projectID: UUID) throws {
        try NarrationDraft.validate([draft])
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw RecordingStoreError.projectNotFound
        }
        var updated = projects
        if let index = updated[projectIndex].narrationDrafts.firstIndex(where: { $0.id == draft.id }) {
            let previous = updated[projectIndex].narrationDrafts[index]
            guard previous.filename == draft.filename, previous.text == draft.text,
                  previous.language == draft.language, previous.voiceProfileID == draft.voiceProfileID,
                  (previous.state == .generating && [.ready, .failed, .cancelled].contains(draft.state))
                    || (previous.state == .ready && draft.state == .cancelled)
            else { throw NarrationDraftError.notReady }
            updated[projectIndex].narrationDrafts[index] = draft
        } else {
            guard draft.state == .generating else { throw NarrationDraftError.notReady }
            updated[projectIndex].narrationDrafts.append(draft)
        }
        try repository.saveProjects(updated)
        projects = updated
    }

    /// Starts a local sentence job after validating ownership. Its storage lease
    /// covers generation, validation and cleanup, not just the initiating call.
    func startNarrationDraft(
        projectID: UUID, voiceProfileID: UUID, text: String, language: String
    ) throws -> NarrationDraft {
        guard project(id: projectID)?.recording != nil else {
            throw RecordingStoreError.projectNotFound
        }
        guard let profile = voiceProfiles.first(where: { $0.id == voiceProfileID && $0.consentConfirmed }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceProfileError.invalidInput
        }
        let prepared = try repository.prepareNarrationURL(projectID: projectID)
        let draft = NarrationDraft(
            voiceProfileID: voiceProfileID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language, filename: prepared.filename
        )
        try saveNarrationDraft(draft, projectID: projectID)
        let operation = beginStorageOperation(.voice)
        narrationTasks[draft.id] = Task {
            defer {
                narrationTasks.removeValue(forKey: draft.id)
                endStorageOperation(operation)
            }
            do {
                try Task.checkCancellation()
                let result = try await voiceService.generate(
                    text: draft.text,
                    referenceAudioURL: repository.voiceReferenceURL(profileID: profile.id, filename: profile.referenceFilename),
                    referenceText: profile.referenceText,
                    language: language,
                    outputURL: prepared.url
                )
                try Task.checkCancellation()
                let measured = try await Self.validatedNarrationDuration(at: prepared.url, reportedDuration: result.duration)
                try Task.checkCancellation()
                guard project(id: projectID)?.narrationDrafts.first(where: { $0.id == draft.id })?.state == .generating else {
                    throw CancellationError()
                }
                var ready = draft
                ready.state = .ready
                ready.duration = measured
                try saveNarrationDraft(ready, projectID: projectID)
            } catch {
                try? FileManager.default.removeItem(at: prepared.url)
                if project(id: projectID)?.narrationDrafts.first(where: { $0.id == draft.id })?.state == .generating {
                    var failed = draft
                    failed.state = error is CancellationError ? .cancelled : .failed
                    failed.error = error.localizedDescription
                    do { try saveNarrationDraft(failed, projectID: projectID) }
                    catch {
                        if let p = projects.firstIndex(where: { $0.id == projectID }),
                           let d = projects[p].narrationDrafts.firstIndex(where: { $0.id == draft.id }) {
                            projects[p].narrationDrafts[d] = failed
                        }
                        errorMessage = "Could not save narration job failure: \(error.localizedDescription)"
                    }
                }
                if project(id: projectID) == nil { try? repository.removeProjectAssets(projectID: projectID) }
            }
        }
        return draft
    }

    /// Cancels running synthesis or discards a ready draft only after recording
    /// the terminal state. A placed draft cannot delete playable audio.
    func cancelNarrationDraft(projectID: UUID, draftID: UUID) throws {
        guard var draft = project(id: projectID)?.narrationDrafts.first(where: { $0.id == draftID }) else {
            throw NarrationDraftError.notReady
        }
        if draft.state == .cancelled {
            let file = repository.assetURL(projectID: projectID, filename: draft.filename)
            if narrationTasks[draftID] == nil, FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        guard draft.state == .generating || draft.state == .ready else {
            throw NarrationDraftError.notReady
        }
        let wasReady = draft.state == .ready
        draft.state = .cancelled
        draft.error = nil
        try saveNarrationDraft(draft, projectID: projectID)
        narrationTasks[draftID]?.cancel()
        if wasReady {
            try FileManager.default.removeItem(
                at: repository.assetURL(projectID: projectID, filename: draft.filename)
            )
        }
    }

    /// Marks interrupted workers as failed without restarting synthesis or
    /// changing the edit revision; completed drafts keep their durable WAVs.
    private static func recoverNarrationDrafts(
        _ projects: [DemoProject], repository: ProjectRepository
    ) throws -> [DemoProject] {
        var recovered = projects
        var changed = false
        for p in recovered.indices {
            try NarrationDraft.validate(recovered[p].narrationDrafts)
            for d in recovered[p].narrationDrafts.indices
            where recovered[p].narrationDrafts[d].state == .generating {
                recovered[p].narrationDrafts[d].state = .failed
                recovered[p].narrationDrafts[d].error = "Generation was interrupted. Create a new draft to retry."
                changed = true
            }
        }
        if changed {
            try repository.saveProjects(recovered)
            for project in projects {
                for draft in project.narrationDrafts where draft.state == .generating {
                    guard !project.narrations.contains(where: { $0.filename == draft.filename }),
                          !project.narrationDrafts.contains(where: { $0.state == .ready && $0.filename == draft.filename }) else { continue }
                    try? FileManager.default.removeItem(
                        at: repository.assetURL(projectID: project.id, filename: draft.filename)
                    )
                }
            }
        }
        return recovered
    }

    /// Reuses a measured ready WAV after a timing conflict. The consumed state
    /// and layer share the same atomic write, so restart and undo cannot replay it.
    func placeNarrationDraft(
        projectID: UUID, draftID: UUID, expectedRevision: Int, startTime: Double,
        timingMode: LayerTimingMode = .project
    ) async throws -> DemoProject {
        let operation = beginStorageOperation(.voice)
        defer { endStorageOperation(operation) }
        guard var project = project(id: projectID) else {
            throw RecordingStoreError.projectNotFound
        }
        guard project.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(project.revision)
        }
        guard let draft = project.narrationDrafts.first(where: { $0.id == draftID }),
              draft.state == .ready, let duration = draft.duration else {
            throw NarrationDraftError.notReady
        }
        _ = try await Self.validatedNarrationDuration(
            at: repository.assetURL(projectID: projectID, filename: draft.filename),
            reportedDuration: duration
        )
        try Task.checkCancellation()
        project.narrations.append(NarrationClip(
            id: draft.id, voiceProfileID: draft.voiceProfileID, filename: draft.filename,
            text: draft.text, language: draft.language, startTime: startTime, duration: duration,
            sceneAnchor: timingMode == .scene ? try SceneTiming.anchor(at: startTime, in: project) : nil
        ))
        project.narrations.sort { $0.startTime < $1.startTime }
        return try saveProject(project, expectedRevision: expectedRevision, placingDraftID: draftID)
    }

    /// Preserves terminal suggestion states while allowing applied or rejected
    /// metadata cleanup only after the referenced Click Cue has been removed.
    /// Duplicate IDs fail before indexing so malformed replacements cannot trap
    /// and discard the current session's undo/redo history.
    private static func validateTransition(
        from current: DemoProject,
        to updated: DemoProject
    ) throws {
        var updatedByID: [UUID: ClickEditSuggestion] = [:]
        for suggestion in updated.suggestions {
            guard updatedByID.updateValue(suggestion, forKey: suggestion.id) == nil else {
                throw VideoProjectValidationError.invalidSuggestion(suggestion.id)
            }
        }
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
        var replacement = previous
        replacement.revision = current.revision
        let saved = try saveProject(replacement, expectedRevision: current.revision, recordUndo: false)
        undoHistory[projectID] = history
        redoHistory[projectID, default: []].append(current)
        return saved
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
        var replacement = next
        replacement.revision = current.revision
        let saved = try saveProject(replacement, expectedRevision: current.revision, recordUndo: false)
        redoHistory[projectID] = history
        undoHistory[projectID, default: []].append(current)
        return saved
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

    /// Creates a project only after native-selected or MCP-supplied media has been
    /// copied and validated. Reserved identities support replay reconciliation;
    /// cancellation and failed publication remove the unpublished copy.
    func importVideo(
        from sourceURL: URL, projectID: UUID = UUID(),
        didCopyBytes: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> UUID {
        let operation = beginStorageOperation(.importing)
        defer { endStorageOperation(operation) }
        let fileExtension = try LocalVideoImporter.supportedFileExtension(
            for: sourceURL
        )
        guard project(id: projectID) == nil else { throw AgentEditError.invalidField("project_id") }
        let prepared = try repository.prepareImportedVideoURL(
            projectID: projectID,
            fileExtension: fileExtension
        )
        do {
            let metadata = try await LocalVideoImporter.copyAndInspect(
                sourceURL: sourceURL,
                destinationURL: prepared.url,
                didCopyBytes: didCopyBytes
            )
            try Task.checkCancellation()
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

    /// Copies only playable project assets before publishing a new independent
    /// language version. Rechecks revision after I/O and cleans incomplete copies.
    func duplicateProject(
        projectID: UUID,
        expectedRevision: Int,
        name: String? = nil
    ) async throws -> DemoProject {
        let operation = beginStorageOperation(.importing)
        defer { endStorageOperation(operation) }
        guard let source = project(id: projectID),
              let recording = source.recording else {
            throw RecordingStoreError.projectNotFound
        }
        guard source.revision == expectedRevision else {
            throw RecordingStoreError.revisionConflict(source.revision)
        }
        try VideoProjectValidator.validate(source)
        let newID = UUID()
        var copy = source
        copy.id = newID
        copy.revision = 0
        copy.name = name ?? "\(source.name) copy"
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        copy.narrationDrafts = []
        copy.audioAssets = source.availableAudioAssets.filter { asset in source.narrations.contains { $0.filename == asset.filename } }
        guard !copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceProfileError.invalidInput
        }
        let directory = repository.assetsDirectory(projectID: newID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await LocalVideoImporter.copyAndInspect(
                sourceURL: repository.assetURL(projectID: projectID, filename: recording.filename),
                destinationURL: directory.appendingPathComponent(recording.filename)
            )
            for filename in Set(source.narrations.map(\.filename)) {
                let destination = directory.appendingPathComponent(filename)
                try FileManager.default.copyItem(
                    at: repository.assetURL(projectID: projectID, filename: filename),
                    to: destination
                )
                for narration in source.narrations where narration.filename == filename {
                    _ = try await Self.validatedNarrationDuration(
                        at: destination, reportedDuration: narration.sourceDuration
                    )
                }
            }
            try Task.checkCancellation()
            guard let current = project(id: projectID) else {
                throw RecordingStoreError.projectNotFound
            }
            guard current.revision == expectedRevision else {
                throw RecordingStoreError.revisionConflict(current.revision)
            }
            try publishNewVideoProject(copy)
            return copy
        } catch {
            try? repository.removeProjectAssets(projectID: newID)
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

    /// Commits deletion before removing assets, so a failed index write cannot
    /// leave the previous durable project pointing at deleted media.
    func deleteProject(id: UUID) {
        guard let project = project(id: id) else { return }
        do {
            let remaining = projects.filter { $0.id != id }
            try repository.saveProjects(remaining)
            projects = remaining
            for draft in project.narrationDrafts { narrationTasks[draft.id]?.cancel() }
            undoHistory.removeValue(forKey: id)
            redoHistory.removeValue(forKey: id)
            if selectedProjectID == id { selectedProjectID = projects.first?.id }
            try repository.removeProjectAssets(projectID: id)
        } catch {
            errorMessage = "Project deletion failed: \(error.localizedDescription)"
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
    case invalidName
    case referenceTooShort
    case profileNotFound
    case microphonePermissionDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Provide a valid MP3/WAV, matching transcript, name, and voice-use consent."
        case .invalidName:
            return "Enter a voice profile name."
        case .referenceTooShort:
            return "The guided microphone recording must contain at least 10 seconds of speech."
        case .profileNotFound:
            return "The selected voice profile no longer exists."
        case .microphonePermissionDenied:
            return "Microphone access is required for this voice recording."
        case .microphoneUnavailable:
            return "No usable microphone is available. Check the input device in Storybird Settings."
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

enum AudioSessionError: LocalizedError {
    case busy
    var errorDescription: String? {
        "Finish the current screen or microphone recording before starting another."
    }
}
