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
    public var subtitlePosition: SubtitlePosition
    public var subtitleStyle: TextOverlayStyle
    public var assetFilename: String
    public var hotspots: [Hotspot]

    public init(
        id: UUID = UUID(),
        title: String,
        caption: String = "",
        subtitlePosition: SubtitlePosition = .bottom,
        subtitleStyle: TextOverlayStyle = .default,
        assetFilename: String,
        hotspots: [Hotspot] = []
    ) {
        self.id = id
        self.title = title
        self.caption = caption
        self.subtitlePosition = subtitlePosition
        self.subtitleStyle = subtitleStyle
        self.assetFilename = assetFilename
        self.hotspots = hotspots
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case caption
        case subtitlePosition
        case subtitleStyle
        case assetFilename
        case hotspots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        caption = try container.decode(String.self, forKey: .caption)
        subtitlePosition = try container.decodeIfPresent(
            SubtitlePosition.self,
            forKey: .subtitlePosition
        ) ?? .bottom
        subtitleStyle = try container.decodeIfPresent(
            TextOverlayStyle.self,
            forKey: .subtitleStyle
        ) ?? .default
        assetFilename = try container.decode(String.self, forKey: .assetFilename)
        hotspots = try container.decode([Hotspot].self, forKey: .hotspots)
    }
}

public struct Hotspot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var kind: HotspotKind
    public var title: String
    public var body: String
    public var caption: String
    public var captionStyle: TextOverlayStyle
    public var targetStepID: UUID?

    public init(
        id: UUID = UUID(),
        x: Double,
        y: Double,
        kind: HotspotKind = .click,
        title: String = "Continue",
        body: String = "",
        caption: String = "",
        captionStyle: TextOverlayStyle = .default,
        targetStepID: UUID? = nil
    ) {
        self.id = id
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.kind = kind
        self.title = title
        self.body = body
        self.caption = caption
        self.captionStyle = captionStyle
        self.targetStepID = targetStepID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case x
        case y
        case kind
        case title
        case body
        case caption
        case captionStyle
        case targetStepID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        kind = try container.decode(HotspotKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        caption = try container.decodeIfPresent(
            String.self,
            forKey: .caption
        ) ?? ""
        captionStyle = try container.decodeIfPresent(
            TextOverlayStyle.self,
            forKey: .captionStyle
        ) ?? .default
        targetStepID = try container.decodeIfPresent(
            UUID.self,
            forKey: .targetStepID
        )
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

public enum SubtitlePosition: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case top
    case bottom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .top:
            return "Top"
        case .bottom:
            return "Bottom"
        }
    }
}

public struct TextOverlayStyle: Codable, Hashable, Sendable {
    public var backgroundHex: String
    public var backgroundOpacity: Double {
        didSet {
            backgroundOpacity = Self.clampedOpacity(backgroundOpacity)
        }
    }

    public init(
        backgroundHex: String = "#11131A",
        backgroundOpacity: Double = 0.72
    ) {
        self.backgroundHex = backgroundHex
        self.backgroundOpacity = Self.clampedOpacity(backgroundOpacity)
    }

    public static let `default` = TextOverlayStyle()

    private enum CodingKeys: String, CodingKey {
        case backgroundHex
        case backgroundOpacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backgroundHex = try container.decodeIfPresent(
            String.self,
            forKey: .backgroundHex
        ) ?? Self.default.backgroundHex
        backgroundOpacity = Self.clampedOpacity(
            try container.decodeIfPresent(
                Double.self,
                forKey: .backgroundOpacity
            ) ?? Self.default.backgroundOpacity
        )
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        min(max(value, 0), 1)
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
