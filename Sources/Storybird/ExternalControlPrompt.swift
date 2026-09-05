import Foundation

struct ExternalControlPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
}
