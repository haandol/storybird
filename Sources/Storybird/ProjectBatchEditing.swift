import Foundation
import StorybirdCore

struct ProjectBatchEditResult: Codable {
    var status: String
    var baseRevision: Int
    var revision: Int
    var wouldChange: Bool
    var idsProvisional: Bool
    var project: DemoProject
    var timelineDuration: Double
    var directChanges: [ProjectEditReference]
    var derivedChanges: [ProjectEditReference]
    var created: [ProjectEditCreation]

    enum CodingKeys: String, CodingKey {
        case status, revision, project, created
        case baseRevision = "base_revision"
        case wouldChange = "would_change"
        case idsProvisional = "ids_provisional"
        case directChanges = "direct_changes"
        case timelineDuration = "timeline_duration"
        case derivedChanges = "derived_changes"
    }
}

extension AppStore {
    /// Both entry points plan from the current app-owned snapshot. Preview never
    /// invokes the writer; apply publishes exactly once through its normal undo
    /// and atomic-write boundary. New preview IDs are deliberately provisional.
    func editProject(projectID: UUID, expectedRevision: Int, edits: [ProjectEdit],
                     preview: Bool = false) throws -> ProjectBatchEditResult {
        guard let original = project(id: projectID) else { throw RecordingStoreError.projectNotFound }
        guard expectedRevision == original.revision else { throw RecordingStoreError.revisionConflict(original.revision) }
        let plan = try ProjectEditPlanner.plan(edits, in: original)
        let saved = preview ? plan.project : try saveProject(plan.project, expectedRevision: expectedRevision)
        return ProjectBatchEditResult(status: preview ? "previewed" : "applied", baseRevision: expectedRevision,
            revision: saved.revision, wouldChange: plan.project != original, idsProvisional: preview,
            project: saved, timelineDuration: saved.timelineDuration,
            directChanges: plan.direct, derivedChanges: plan.derived, created: plan.created)
    }
}
