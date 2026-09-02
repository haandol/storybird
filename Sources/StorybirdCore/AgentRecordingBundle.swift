import AppKit
import CoreGraphics
import Foundation

struct AgentRecordingManifest: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var projectName: String
    var sourceName: String
    var steps: [Step]

    init(
        version: Int = Self.currentVersion,
        projectName: String,
        sourceName: String,
        steps: [Step]
    ) {
        self.version = version
        self.projectName = projectName
        self.sourceName = sourceName
        self.steps = steps
    }

    struct Step: Codable, Hashable, Sendable {
        var assetFilename: String
        var clickFromPrevious: Click?

        init(
            assetFilename: String,
            clickFromPrevious: Click? = nil
        ) {
            self.assetFilename = assetFilename
            self.clickFromPrevious = clickFromPrevious
        }
    }

    struct Click: Codable, Hashable, Sendable {
        var x: Double
        var y: Double

        init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }
}

enum AgentRecordingBundleError: LocalizedError {
    case invalidPackage
    case unsupportedVersion(Int)
    case missingProjectName
    case missingSourceName
    case emptyRecording
    case invalidTransition(Int)
    case invalidCoordinate(Int)
    case invalidAssetName(String)
    case unexpectedManifestField(String)
    case unexpectedPackageEntry(String)
    case missingAsset(String)
    case symbolicLink(String)
    case unreadableAsset(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The selected item is not a Storybird recording package."
        case let .unsupportedVersion(version):
            return "Storybird does not support recording package version \(version)."
        case .missingProjectName:
            return "The recording package does not include a project name."
        case .missingSourceName:
            return "The recording package does not include a source name."
        case .emptyRecording:
            return "The recording package does not include any screens."
        case let .invalidTransition(index):
            return "Screen \(index + 1) has an invalid preceding click."
        case let .invalidCoordinate(index):
            return "Screen \(index + 1) has a click outside the normalized capture frame."
        case let .invalidAssetName(filename):
            return "The recording package contains an invalid asset name: \(filename)"
        case let .unexpectedManifestField(field):
            return "The recording manifest contains an unsupported field: \(field)"
        case let .unexpectedPackageEntry(name):
            return "The recording package contains an unexpected item: \(name)"
        case let .missingAsset(filename):
            return "The recording package is missing \(filename)."
        case let .symbolicLink(name):
            return "The recording package cannot contain symbolic links: \(name)"
        case let .unreadableAsset(filename):
            return "Storybird could not read \(filename) as a PNG image."
        }
    }
}

struct AgentRecordingBundleImporter {
    static let packageExtension = "storybirdrecording"
    static let manifestFilename = "manifest.json"
    static let assetsDirectoryName = "assets"

    private let repository: ProjectRepository
    private let decoder: JSONDecoder

    init(repository: ProjectRepository) {
        self.repository = repository
        decoder = JSONDecoder()
    }

    func importBundle(at packageURL: URL) throws -> DemoProject {
        let prepared = try preparePackage(at: packageURL)
        let projectID = UUID()
        var project = DemoProject(
            id: projectID,
            name: prepared.manifest.projectName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            summary: "Agent recording from \(prepared.manifest.sourceName)"
        )

        do {
            var previousStepID: UUID?
            for (index, item) in prepared.steps.enumerated() {
                let filename = try repository.writeImage(
                    item.image,
                    projectID: projectID
                )
                let manifestStep = item.step
                let step = DemoStep(
                    title: "Agent screen \(index + 1)",
                    assetFilename: filename
                )

                if let previousStepID,
                   let click = manifestStep.clickFromPrevious {
                    try RecordedFlowBuilder.append(
                        nextStep: step,
                        clickPoint: CGPoint(x: click.x, y: click.y),
                        from: previousStepID,
                        to: &project
                    )
                } else {
                    project.steps.append(step)
                }
                previousStepID = step.id
            }
            return project
        } catch {
            try? repository.removeProjectAssets(projectID: projectID)
            throw error
        }
    }

    private func preparePackage(at packageURL: URL) throws -> PreparedPackage {
        guard packageURL.pathExtension.lowercased() == Self.packageExtension,
              try regularDirectory(packageURL)
        else {
            throw AgentRecordingBundleError.invalidPackage
        }
        try validateTopLevelEntries(packageURL)

        let manifestURL = packageURL.appendingPathComponent(
            Self.manifestFilename
        )
        try rejectSymbolicLink(manifestURL)
        guard try regularFile(manifestURL) else {
            throw AgentRecordingBundleError.invalidPackage
        }

        let manifestData = try Data(contentsOf: manifestURL)
        try validateManifestShape(manifestData)
        let manifest = try decoder.decode(
            AgentRecordingManifest.self,
            from: manifestData
        )
        try validateManifest(manifest)

        let assetsURL = packageURL.appendingPathComponent(
            Self.assetsDirectoryName,
            isDirectory: true
        )
        try rejectSymbolicLink(assetsURL)
        guard try regularDirectory(assetsURL) else {
            throw AgentRecordingBundleError.invalidPackage
        }
        try validateAssetDirectory(assetsURL, manifest: manifest)

        let steps = try manifest.steps.map { step in
            let assetURL = assetsURL.appendingPathComponent(
                step.assetFilename
            )
            try rejectSymbolicLink(assetURL)
            guard try regularFile(assetURL) else {
                throw AgentRecordingBundleError.missingAsset(
                    step.assetFilename
                )
            }
            let data = try Data(contentsOf: assetURL, options: .mappedIfSafe)
            guard data.starts(with: Self.pngSignature),
                  let image = NSImage(data: data)
            else {
                throw AgentRecordingBundleError.unreadableAsset(
                    step.assetFilename
                )
            }
            return PreparedStep(step: step, image: image)
        }
        return PreparedPackage(manifest: manifest, steps: steps)
    }

    private func validateManifest(_ manifest: AgentRecordingManifest) throws {
        guard manifest.version == AgentRecordingManifest.currentVersion else {
            throw AgentRecordingBundleError.unsupportedVersion(
                manifest.version
            )
        }
        guard !manifest.projectName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentRecordingBundleError.missingProjectName
        }
        guard !manifest.sourceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentRecordingBundleError.missingSourceName
        }
        guard !manifest.steps.isEmpty else {
            throw AgentRecordingBundleError.emptyRecording
        }

        for (index, step) in manifest.steps.enumerated() {
            try validateAssetName(step.assetFilename)
            if index == 0 {
                guard step.clickFromPrevious == nil else {
                    throw AgentRecordingBundleError.invalidTransition(index)
                }
                continue
            }
            guard let click = step.clickFromPrevious else {
                throw AgentRecordingBundleError.invalidTransition(index)
            }
            guard click.x.isFinite,
                  click.y.isFinite,
                  (0...1).contains(click.x),
                  (0...1).contains(click.y)
            else {
                throw AgentRecordingBundleError.invalidCoordinate(index)
            }
        }
    }

    private func validateManifestShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw AgentRecordingBundleError.invalidPackage
        }
        try rejectUnknownKeys(
            in: root,
            allowed: ["version", "projectName", "sourceName", "steps"],
            prefix: "manifest"
        )
        guard let steps = root["steps"] as? [[String: Any]] else {
            return
        }
        for (index, step) in steps.enumerated() {
            try rejectUnknownKeys(
                in: step,
                allowed: [
                    "assetFilename",
                    "clickFromPrevious",
                ],
                prefix: "steps[\(index)]"
            )
            if let click = step["clickFromPrevious"] as? [String: Any] {
                try rejectUnknownKeys(
                    in: click,
                    allowed: ["x", "y"],
                    prefix: "steps[\(index)].clickFromPrevious"
                )
            }
        }
    }

    private func rejectUnknownKeys(
        in object: [String: Any],
        allowed: Set<String>,
        prefix: String
    ) throws {
        if let key = Set(object.keys).subtracting(allowed).sorted().first {
            throw AgentRecordingBundleError.unexpectedManifestField(
                "\(prefix).\(key)"
            )
        }
    }

    private func validateAssetName(_ filename: String) throws {
        let path = NSString(string: filename)
        guard !filename.isEmpty,
              path.lastPathComponent == filename,
              path.pathExtension.lowercased() == "png",
              !filename.contains("\\")
        else {
            throw AgentRecordingBundleError.invalidAssetName(filename)
        }
    }

    private func validateTopLevelEntries(_ packageURL: URL) throws {
        let allowed = Set([
            Self.manifestFilename,
            Self.assetsDirectoryName,
        ])
        for url in try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil
        ) where !allowed.contains(url.lastPathComponent) {
            throw AgentRecordingBundleError.unexpectedPackageEntry(
                url.lastPathComponent
            )
        }
    }

    private func validateAssetDirectory(
        _ assetsURL: URL,
        manifest: AgentRecordingManifest
    ) throws {
        let expected = Set(manifest.steps.map(\.assetFilename))
        let actual = Set(
            try FileManager.default.contentsOfDirectory(
                at: assetsURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        guard expected == actual else {
            let unexpected = actual.subtracting(expected).sorted().first
            if let unexpected {
                throw AgentRecordingBundleError.unexpectedPackageEntry(
                    unexpected
                )
            }
            throw AgentRecordingBundleError.missingAsset(
                expected.subtracting(actual).sorted().first ?? "asset"
            )
        }
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw AgentRecordingBundleError.symbolicLink(
                url.lastPathComponent
            )
        }
    }

    private func regularDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func regularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static let pngSignature = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ])
}

public struct AgentRecordingLibraryImporter {
    private let repository: ProjectRepository

    public init(repository: ProjectRepository) {
        self.repository = repository
    }

    public func importBundle(
        at packageURL: URL,
        into projects: [DemoProject]
    ) throws -> (project: DemoProject, projects: [DemoProject]) {
        let project = try AgentRecordingBundleImporter(
            repository: repository
        ).importBundle(at: packageURL)
        var updatedProjects = projects
        updatedProjects.insert(project, at: 0)

        do {
            try repository.saveProjects(updatedProjects)
            return (project, updatedProjects)
        } catch {
            try? repository.removeProjectAssets(projectID: project.id)
            throw error
        }
    }
}

private struct PreparedPackage {
    let manifest: AgentRecordingManifest
    let steps: [PreparedStep]
}

private struct PreparedStep {
    let step: AgentRecordingManifest.Step
    let image: NSImage
}
