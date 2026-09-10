import Foundation

/// Stores only the user's explicit project-folder choice. Tests inject a
/// private defaults suite; injected repositories do not use standard defaults.
struct StorybirdStoragePreferences {
    private let defaults: UserDefaults
    private let key = "projectLibraryRootPath"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedRootURL: URL? {
        guard let path = defaults.string(forKey: key), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func save(_ url: URL?) {
        if let url {
            defaults.set(url.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

enum StorageOperation: String {
    case recording = "recording"
    case importing = "video import"
    case voice = "voice work"
    case microphone = "microphone recording"
    case externalCommand = "MCP work"
}
