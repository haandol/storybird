import Combine
import Foundation
import StorybirdCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var projects: [DemoProject] = []
    @Published var selectedProjectID: UUID?
    @Published var errorMessage: String?
    @Published var permissionPrompt: RecordingPermissionPrompt?
    @Published var externalControlPrompt: ExternalControlPrompt?
    @Published var requestedPreviewProjectID: UUID?

    let repository: ProjectRepository
    private var externalControlContinuation:
        CheckedContinuation<Bool, Never>?
    private var undoHistory: [UUID: [DemoProject]] = [:]
    private var redoHistory: [UUID: [DemoProject]] = [:]

    init(repository: ProjectRepository? = nil) {
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
            selectedProjectID = projects.first?.id
        } catch {
            projects = []
            errorMessage = "Storybird could not open its library: \(error.localizedDescription)"
        }
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

    /// Preserves terminal suggestion states while still allowing rejected suggestions to leave with a deleted cue.
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
                guard updatedByID[suggestion.id]?.state == .applied else {
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
            try VideoProjectValidator.validate(project)

            var updatedProjects = projects
            updatedProjects.insert(project, at: 0)
            try repository.saveProjects(updatedProjects)
            projects = updatedProjects
            selectedProjectID = projectID
        } catch {
            try? repository.removeProjectAssets(projectID: projectID)
            throw error
        }
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

enum RecordingStoreError: LocalizedError {
    case projectNotFound
    case videoNotFound
    case revisionConflict(Int)
    case noUndo
    case noRedo
    case invalidSuggestionTransition

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
