import Foundation

/// A permanent deletion can remove the index successfully before asset cleanup
/// fails. Keep both outcomes visible instead of claiming success or rollback.
struct ProjectDeletionResult: Codable, Equatable, Sendable {
    let projectID: UUID
    let status: String
    let projectRemoved: Bool
    let assetsRemoved: Bool
    var currentRevision: Int?
    var code: String?
    var message: String?

    var isError: Bool { status == "failed" }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case status
        case projectRemoved = "project_removed"
        case assetsRemoved = "assets_removed"
        case currentRevision = "current_revision"
        case code, message
    }
}
