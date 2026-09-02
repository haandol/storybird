import AppKit
import Foundation

public enum RepositoryError: LocalizedError {
    case applicationSupportUnavailable
    case unreadableImage
    case pngEncodingFailed
    case legacyMigrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support folder is unavailable."
        case .unreadableImage:
            return "The selected file is not a readable image."
        case .pngEncodingFailed:
            return "Storybird could not encode the captured image."
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

    public func assetURL(projectID: UUID, filename: String) -> URL {
        projectAssetsURL(projectID: projectID)
            .appendingPathComponent(filename)
    }

    public func assetsDirectory(projectID: UUID) -> URL {
        projectAssetsURL(projectID: projectID)
    }

    public func importImage(at sourceURL: URL, projectID: UUID) throws -> String {
        guard let image = NSImage(contentsOf: sourceURL) else {
            throw RepositoryError.unreadableImage
        }
        return try writeImage(image, projectID: projectID)
    }

    public func writeImage(_ image: NSImage, projectID: UUID) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(
                using: .png,
                properties: [:]
              )
        else {
            throw RepositoryError.pngEncodingFailed
        }
        return try writePNGData(data, projectID: projectID)
    }

    public func writePNGData(_ data: Data, projectID: UUID) throws -> String {
        let filename = "\(UUID().uuidString.lowercased()).png"
        let directory = projectAssetsURL(projectID: projectID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
        return filename
    }

    public func removeAsset(projectID: UUID, filename: String) throws {
        let url = assetURL(projectID: projectID, filename: filename)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
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

    private func projectAssetsURL(projectID: UUID) -> URL {
        assetsRootURL.appendingPathComponent(
            projectID.uuidString.lowercased(),
            isDirectory: true
        )
    }
}
