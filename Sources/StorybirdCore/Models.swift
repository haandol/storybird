import Foundation

public struct DemoProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var steps: [DemoStep]
    public var events: [AnalyticsEvent]
    public var theme: DemoTheme

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        steps: [DemoStep] = [],
        events: [AnalyticsEvent] = [],
        theme: DemoTheme = .openLane
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.steps = steps
        self.events = events
        self.theme = theme
    }
}

public struct DemoStep: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var caption: String
    public var assetFilename: String
    public var hotspots: [Hotspot]

    public init(
        id: UUID = UUID(),
        title: String,
        caption: String = "",
        assetFilename: String,
        hotspots: [Hotspot] = []
    ) {
        self.id = id
        self.title = title
        self.caption = caption
        self.assetFilename = assetFilename
        self.hotspots = hotspots
    }
}

public struct Hotspot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var kind: HotspotKind
    public var title: String
    public var body: String
    public var targetStepID: UUID?

    public init(
        id: UUID = UUID(),
        x: Double,
        y: Double,
        kind: HotspotKind = .click,
        title: String = "Continue",
        body: String = "",
        targetStepID: UUID? = nil
    ) {
        self.id = id
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.kind = kind
        self.title = title
        self.body = body
        self.targetStepID = targetStepID
    }
}

public enum HotspotKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case click
    case information

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .click:
            return "Click"
        case .information:
            return "Information"
        }
    }
}

public struct DemoTheme: Codable, Hashable, Sendable {
    public var accentHex: String
    public var backgroundHex: String
    public var showsBranding: Bool

    public init(
        accentHex: String,
        backgroundHex: String,
        showsBranding: Bool = true
    ) {
        self.accentHex = accentHex
        self.backgroundHex = backgroundHex
        self.showsBranding = showsBranding
    }

    public static let openLane = DemoTheme(
        accentHex: "#5B5CE2",
        backgroundHex: "#11131A"
    )
}

public struct AnalyticsEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var timestamp: Date
    public var type: AnalyticsEventType
    public var stepID: UUID?
    public var hotspotID: UUID?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        timestamp: Date = Date(),
        type: AnalyticsEventType,
        stepID: UUID? = nil,
        hotspotID: UUID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.type = type
        self.stepID = stepID
        self.hotspotID = hotspotID
    }
}

public enum AnalyticsEventType: String, Codable, Hashable, Sendable {
    case sessionStarted
    case stepViewed
    case hotspotClicked
    case completed
}
