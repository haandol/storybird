/// A release version has exactly three numeric components; build numbers do not
/// participate in ordering. GitHub tags may add a lowercase `v` prefix.
public struct AppVersion: Comparable, Sendable {
    private let components: [Int]

    /// Reject incomplete or nonnumeric versions instead of guessing missing components.
    public init?(_ value: String, allowingTagPrefix: Bool = false) {
        let text = allowingTagPrefix && value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }

    /// Compare numbers component by component so 0.10.0 sorts after 0.9.0.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

public struct AppUpdateStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case idle, checking, failed
        case upToDate = "up_to_date"
        case updateAvailable = "update_available"
    }

    public var state: State
    public let currentVersion: String?
    public let buildNumber: String?
    public var latestVersion: String?
    public var releaseURL: String?
    public var error: String?

    /// Keep display metadata and transient results together for native and MCP clients.
    public init(state: State = .idle, currentVersion: String?, buildNumber: String?,
                latestVersion: String? = nil, releaseURL: String? = nil, error: String? = nil) {
        self.state = state
        self.currentVersion = currentVersion
        self.buildNumber = buildNumber
        self.latestVersion = latestVersion
        self.releaseURL = releaseURL
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case state, error
        case currentVersion = "current_version"
        case buildNumber = "build_number"
        case latestVersion = "latest_version"
        case releaseURL = "release_url"
    }
}
