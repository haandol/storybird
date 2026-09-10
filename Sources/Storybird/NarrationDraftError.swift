import Foundation

enum NarrationDraftError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "The narration draft is not ready or has already been placed."
    }
}
