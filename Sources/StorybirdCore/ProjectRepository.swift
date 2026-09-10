import Foundation

public enum RepositoryError: LocalizedError {
    case applicationSupportUnavailable
    case legacyMigrationFailed(String)
    case storageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support folder is unavailable."
        case let .legacyMigrationFailed(reason):
            return "Storybird could not copy the existing OpenLane library: \(reason)"
        case let .storageUnavailable(reason):
            return "The project folder is unavailable: \(reason)"
        }
    }
}

public struct ProjectRepository {
    public let rootURL: URL
    public let sharedRootURL: URL

    private let fileManager: FileManager
    private let requiresExistingRoot: Bool
    private let unavailableReason: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootURL: URL,
        sharedRootURL: URL? = nil,
        requiresExistingRoot: Bool = false,
        unavailableReason: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.sharedRootURL = sharedRootURL ?? rootURL
        self.requiresExistingRoot = requiresExistingRoot
        self.unavailableReason = unavailableReason
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Resolves the user-visible project home without creating files.
    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("Storybird", isDirectory: true)
    }

    /// Shared voice assets and local IPC retain their Application Support home.
    public static func sharedRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RepositoryError.applicationSupportUnavailable
        }

        return applicationSupport.appendingPathComponent(
            "Storybird",
            isDirectory: true
        )
    }

    /// Selects Documents projects separately from shared Application Support assets.
    /// Copies OpenLane only when the shared Storybird root is absent, and propagates
    /// location or migration failures rather than silently choosing another library.
    public static func live(fileManager: FileManager = .default) throws -> ProjectRepository {
        let storybirdURL = try sharedRootURL(fileManager: fileManager)
        let legacyURL = storybirdURL.deletingLastPathComponent().appendingPathComponent(
            "OpenLane",
            isDirectory: true
        )
        try migrateLegacyLibraryIfNeeded(
            from: legacyURL,
            to: storybirdURL,
            fileManager: fileManager
        )

        return ProjectRepository(
            rootURL: try defaultRootURL(fileManager: fileManager),
            sharedRootURL: storybirdURL,
            fileManager: fileManager
        )
    }

    /// Publishes a legacy copy only after all bytes reach a sibling staging folder.
    /// Failed copies leave the original and existing destination untouched so a
    /// later launch can retry without mistaking partial output for a complete root.
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

        let stagingURL = storybirdURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(storybirdURL.lastPathComponent)-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            try fileManager.copyItem(at: legacyURL, to: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: storybirdURL)
        } catch {
            throw RepositoryError.legacyMigrationFailed(
                error.localizedDescription
            )
        }
    }

    public func prepare() throws {
        try checkProjectAccess()
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
        return try readProjects()
    }

    private func readProjects() throws -> [DemoProject] {
        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return []
        }
        let data = try Data(contentsOf: libraryURL)
        return try decoder.decode([DemoProject].self, from: data)
    }

    /// Validates a candidate without replacing its index or moving any assets.
    /// The write probe catches ACL/read-only-volume failures that preflight can miss.
    public func validatedProjectsForSelection() throws -> [DemoProject] {
        try requireDirectory(rootURL)
        let projects = try readProjects()
        guard Set(projects.map(\.id)).count == projects.count else {
            throw RepositoryError.storageUnavailable("The library contains duplicate projects.")
        }
        for project in projects {
            if project.recording != nil || !project.narrations.isEmpty {
                try VideoProjectValidator.validate(project)
            }
            let filenames = [project.recording?.filename].compactMap { $0 }
                + project.narrations.map(\.filename)
                + project.audioAssets.map(\.filename)
                + project.narrationDrafts.filter { $0.state == .ready }.map(\.filename)
            for filename in filenames {
                let asset = assetURL(projectID: project.id, filename: filename)
                let values = try asset.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true,
                      fileManager.isReadableFile(atPath: asset.path)
                else {
                    throw RepositoryError.storageUnavailable("A project asset cannot be read.")
                }
            }
        }
        try probeWrite(in: rootURL)
        if fileManager.fileExists(atPath: assetsRootURL.path) {
            try requireDirectory(assetsRootURL)
            try probeWrite(in: assetsRootURL)
        }
        return projects
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard url.isFileURL, values.isDirectory == true,
              fileManager.isReadableFile(atPath: url.path)
        else {
            throw RepositoryError.storageUnavailable("Choose a readable folder on this Mac.")
        }
    }

    private func probeWrite(in directory: URL) throws {
        let probe = directory.appendingPathComponent(
            ".storybird-write-check-\(UUID().uuidString)"
        )
        try Data("Storybird".utf8).write(to: probe, options: .withoutOverwriting)
        do {
            try fileManager.removeItem(at: probe)
        } catch {
            throw RepositoryError.storageUnavailable(error.localizedDescription)
        }
    }

    private func checkProjectAccess() throws {
        if let unavailableReason {
            throw RepositoryError.storageUnavailable(unavailableReason)
        }
        if requiresExistingRoot {
            try requireDirectory(rootURL)
        }
    }

    public func saveProjects(_ projects: [DemoProject]) throws {
        try prepare()
        let data = try encoder.encode(projects)
        try data.write(to: libraryURL, options: .atomic)
    }

    /// Loads the local profile index without reading or returning reference
    /// audio bytes.
    public func loadVoiceProfiles() throws -> [VoiceProfile] {
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
        try checkProjectAccess()
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
        try checkProjectAccess()
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
        try checkProjectAccess()
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
        sharedRootURL.appendingPathComponent("Voices", isDirectory: true)
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
