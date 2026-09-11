import CoreFoundation
import Foundation

/// App-wide preferences live in the user's plist, separate from project libraries.
/// Tests inject a private defaults suite and never read the user's settings.
struct StorybirdRecordingPreferences {
    private let defaults: UserDefaults
    private let autoApprovalKey = "storybird.mcpRecordingAutoApproval"

    /// Keeps production settings in the bundle's domain and permits isolated tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Only an explicitly stored boolean can enable automatic screen control.
    var automaticallyApprovesMCPRecording: Bool {
        guard let value = defaults.object(forKey: autoApprovalKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    /// Stores only the selected boolean; persistence itself starts no capture.
    func saveAutomaticallyApprovesMCPRecording(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoApprovalKey)
    }
}
