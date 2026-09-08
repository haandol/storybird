import Foundation

public enum RepositoryError: LocalizedError {
    case applicationSupportUnavailable
    case legacyMigrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support folder is unavailable."
        case let .legacyMigrationFailed(reason):
            return "Storybird could not copy the existing OpenLane library: \(reason)"
        }
    }
}

public struct ProjectRepository {
    public let rootURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func live(fileManager: FileManager = .default) throws -> ProjectRepository {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RepositoryError.applicationSupportUnavailable
        }

        let storybirdURL = applicationSupport.appendingPathComponent(
            "Storybird",
            isDirectory: true
        )
        let legacyURL = applicationSupport.appendingPathComponent(
            "OpenLane",
            isDirectory: true
        )
        try migrateLegacyLibraryIfNeeded(
            from: legacyURL,
            to: storybirdURL,
            fileManager: fileManager
        )

        return ProjectRepository(rootURL: storybirdURL, fileManager: fileManager)
    }

    public static func migrateLegacyLibraryIfNeeded(
        from legacyURL: URL,
        to storybirdURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !fileManager.fileExists(atPath: storybirdURL.path),
              fileManager.fileExists(atPath: legacyURL.path)
        else {
            return
        }

        do {
            try fileManager.copyItem(at: legacyURL, to: storybirdURL)
        } catch {
            throw RepositoryError.legacyMigrationFailed(
                error.localizedDescription
            )
        }
    }

    public func prepare() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: assetsRootURL,
            withIntermediateDirectories: true
        )
    }

    public func loadProjects() throws -> [DemoProject] {
        try prepare()
        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return []
        }
        let data = try Data(contentsOf: libraryURL)
        return try decoder.decode([DemoProject].self, from: data)
    }

    public func saveProjects(_ projects: [DemoProject]) throws {
        try prepare()
        let data = try encoder.encode(projects)
        try data.write(to: libraryURL, options: .atomic)
    }

    /// Loads the local profile index without reading or returning reference
    /// audio bytes.
    public func loadVoiceProfiles() throws -> [VoiceProfile] {
        try prepare()
        guard fileManager.fileExists(atPath: voiceProfilesURL.path) else {
            return []
        }
        return try decoder.decode(
            [VoiceProfile].self,
            from: Data(contentsOf: voiceProfilesURL)
        )
    }

    /// Atomically replaces the local profile index after its referenced audio
    /// has been copied into Storybird-owned storage.
    public func saveVoiceProfiles(_ profiles: [VoiceProfile]) throws {
        try prepare()
        try fileManager.createDirectory(
            at: voicesRootURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(profiles).write(
            to: voiceProfilesURL,
            options: .atomic
        )
    }

    /// Resolves a profile-owned reference file while keeping it separate from
    /// every project-owned generated narration asset.
    public func voiceReferenceURL(
        profileID: UUID,
        filename: String
    ) -> URL {
        voiceProfileDirectory(profileID: profileID)
            .appendingPathComponent(filename)
    }

    /// Creates the profile directory and reserves the single supported reference
    /// filename before the caller copies a validated MP3 or WAV.
    public func prepareVoiceReferenceURL(
        profileID: UUID,
        fileExtension: String
    ) throws -> (filename: String, url: URL) {
        let directory = voiceProfileDirectory(profileID: profileID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let filename = "reference.\(fileExtension.lowercased())"
        return (filename, directory.appendingPathComponent(filename))
    }

    /// Removes only sensitive profile-owned reference data so deleting a profile
    /// cannot remove narration already owned by projects.
    public func removeVoiceProfileAssets(profileID: UUID) throws {
        let directory = voiceProfileDirectory(profileID: profileID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Reserves a unique project-owned WAV path that is published in the library
    /// only after synthesis and timeline validation succeed.
    public func prepareNarrationURL(
        projectID: UUID
    ) throws -> (filename: String, url: URL) {
        let filename = "narration-\(UUID().uuidString.lowercased()).wav"
        let directory = projectAssetsURL(projectID: projectID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (filename, directory.appendingPathComponent(filename))
    }

    public func assetURL(projectID: UUID, filename: String) -> URL {
        projectAssetsURL(projectID: projectID)
            .appendingPathComponent(filename)
    }

    public func assetsDirectory(projectID: UUID) -> URL {
        projectAssetsURL(projectID: projectID)
    }

    /// Reserves a project-owned MP4 path so recording can finish before the library references it.
    public func prepareVideoRecordingURL(
        projectID: UUID
    ) throws -> (filename: String, url: URL) {
        try prepareProjectMovieURL(
            projectID: projectID,
            fileExtension: "mp4"
        )
    }

    /// Reserves a project-owned movie path so an imported source can be copied and
    /// validated before the library publishes a project that references it.
    public func prepareImportedVideoURL(
        projectID: UUID,
        fileExtension: String
    ) throws -> (filename: String, url: URL) {
        try prepareProjectMovieURL(
            projectID: projectID,
            fileExtension: fileExtension.lowercased()
        )
    }

    /// Creates one unique project-owned movie location while keeping directory
    /// preparation and filename generation identical for recording and import.
    private func prepareProjectMovieURL(
        projectID: UUID,
        fileExtension: String
    ) throws -> (filename: String, url: URL) {
        let filename =
            "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let directory = projectAssetsURL(projectID: projectID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            filename,
            directory.appendingPathComponent(filename)
        )
    }

    public func removeProjectAssets(projectID: UUID) throws {
        let url = projectAssetsURL(projectID: projectID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private var libraryURL: URL {
        rootURL.appendingPathComponent("library.json")
    }

    private var assetsRootURL: URL {
        rootURL.appendingPathComponent("Assets", isDirectory: true)
    }

    private var voicesRootURL: URL {
        rootURL.appendingPathComponent("Voices", isDirectory: true)
    }

    /// Resolves the single profile-owned directory rule reused by reference
    /// lookup, creation, and sensitive-data deletion.
    private func voiceProfileDirectory(profileID: UUID) -> URL {
        voicesRootURL.appendingPathComponent(
            profileID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private var voiceProfilesURL: URL {
        voicesRootURL.appendingPathComponent("profiles.json")
    }

    private func projectAssetsURL(projectID: UUID) -> URL {
        assetsRootURL.appendingPathComponent(
            projectID.uuidString.lowercased(),
            isDirectory: true
        )
    }
}
