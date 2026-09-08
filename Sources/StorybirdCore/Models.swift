import Foundation

public struct DemoProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var revision: Int
    public var name: String
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var recording: VideoRecordingAsset?
    public var clips: [VideoClip]
    public var clicks: [TimedPointerClick]
    public var subtitles: [TimedSubtitle]
    public var effects: [DemoEffect]
    public var narrations: [NarrationClip]
    public var suggestions: [ClickEditSuggestion]
    public var steps: [DemoStep]
    public var events: [AnalyticsEvent]
    public var theme: DemoTheme

    /// Creates one versioned editing project while preserving legacy defaults
    /// and keeping narration on the same canonical project timeline.
    public init(
        id: UUID = UUID(),
        revision: Int = 0,
        name: String,
        summary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recording: VideoRecordingAsset? = nil,
        clips: [VideoClip] = [],
        clicks: [TimedPointerClick] = [],
        subtitles: [TimedSubtitle] = [],
        effects: [DemoEffect] = [],
        narrations: [NarrationClip] = [],
        suggestions: [ClickEditSuggestion] = [],
        steps: [DemoStep] = [],
        events: [AnalyticsEvent] = [],
        theme: DemoTheme = .openLane
    ) {
        self.id = id
        self.revision = max(revision, 0)
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recording = recording
        if clips.isEmpty, let recording {
            self.clips = [
                VideoClip(
                    sourceStart: 0,
                    sourceEnd: recording.duration
                ),
            ]
        } else {
            self.clips = clips
        }
        self.clicks = clicks
        self.subtitles = subtitles
        self.effects = effects
        self.narrations = narrations
        self.suggestions = suggestions
        self.steps = steps
        self.events = events
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case name
        case summary
        case createdAt
        case updatedAt
        case recording
        case clips
        case clicks
        case subtitles
        case effects
        case narrations
        case suggestions
        case steps
        case events
        case theme
    }

    /// Decodes pre-video projects without treating their screenshot graph as a recording.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        recording = try container.decodeIfPresent(
            VideoRecordingAsset.self,
            forKey: .recording
        )
        clips = try container.decodeIfPresent(
            [VideoClip].self,
            forKey: .clips
        ) ?? []
        clicks = try container.decodeIfPresent(
            [TimedPointerClick].self,
            forKey: .clicks
        ) ?? []
        subtitles = try container.decodeIfPresent(
            [TimedSubtitle].self,
            forKey: .subtitles
        ) ?? []
        effects = try container.decodeIfPresent(
            [DemoEffect].self,
            forKey: .effects
        ) ?? []
        narrations = try container.decodeIfPresent(
            [NarrationClip].self,
            forKey: .narrations
        ) ?? []
        suggestions = try container.decodeIfPresent(
            [ClickEditSuggestion].self,
            forKey: .suggestions
        ) ?? []
        steps = try container.decodeIfPresent(
            [DemoStep].self,
            forKey: .steps
        ) ?? []
        events = try container.decodeIfPresent(
            [AnalyticsEvent].self,
            forKey: .events
        ) ?? []
        theme = try container.decodeIfPresent(
            DemoTheme.self,
            forKey: .theme
        ) ?? .openLane
    }

    public var timelineDuration: Double {
        clips.reduce(0) { $0 + $1.outputDuration }
            + effects.reduce(0) { total, effect in
                if effect.isFullScreenCard {
                    return total + max(effect.endTime - effect.startTime, 0)
                }
                return total
            }
    }
}

public struct VoiceProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var referenceFilename: String
    public var referenceText: String
    public var language: String
    public var consentConfirmed: Bool
    public var createdAt: Date

    /// Creates a consent-bearing local voice profile whose reference audio and
    /// exact transcript remain outside project-owned generated assets.
    public init(
        id: UUID = UUID(),
        name: String,
        referenceFilename: String,
        referenceText: String,
        language: String = "korean",
        consentConfirmed: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.referenceFilename = referenceFilename
        self.referenceText = referenceText
        self.language = language
        self.consentConfirmed = consentConfirmed
        self.createdAt = createdAt
    }
}

public struct NarrationClip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var voiceProfileID: UUID
    public var filename: String
    public var text: String
    public var language: String
    public var startTime: Double
    public var duration: Double
    public var volume: Double

    /// Creates one project-time narration layer that references a complete
    /// project-owned WAV and retains the profile identity used to generate it.
    public init(
        id: UUID = UUID(),
        voiceProfileID: UUID,
        filename: String,
        text: String,
        language: String = "korean",
        startTime: Double,
        duration: Double,
        volume: Double = 1
    ) {
        self.id = id
        self.voiceProfileID = voiceProfileID
        self.filename = filename
        self.text = text
        self.language = language
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
    }

    public var endTime: Double {
        startTime + duration
    }
}

public struct VideoRecordingAsset: Codable, Hashable, Sendable {
    public var filename: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var mediaStartTime: Double?

    public init(
        filename: String,
        duration: Double,
        width: Int,
        height: Int,
        mediaStartTime: Double? = nil
    ) {
        self.filename = filename
        self.duration = max(duration, 0)
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.mediaStartTime = mediaStartTime
    }
}

public enum PointerButton: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case left
    case right

    public var id: String { rawValue }
}

public enum VideoClipKind: String, Codable, Hashable, Sendable {
    case video
    case freeze
}

public struct VideoClip: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: VideoClipKind
    public var sourceStart: Double
    public var sourceEnd: Double
    public var playbackRate: Double
    public var freezeDuration: Double

    public init(
        id: UUID = UUID(),
        kind: VideoClipKind = .video,
        sourceStart: Double,
        sourceEnd: Double,
        playbackRate: Double = 1,
        freezeDuration: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.playbackRate = playbackRate
        self.freezeDuration = freezeDuration
    }

    public var outputDuration: Double {
        switch kind {
        case .video:
            return max(sourceEnd - sourceStart, 0) / max(playbackRate, 0.001)
        case .freeze:
            return max(freezeDuration, 0)
        }
    }
}

public enum ClickDescriptionPosition: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case automatic
    case custom

    public var id: String { rawValue }
}

public struct ClickIndicatorStyle: Codable, Hashable, Sendable {
    public var startTime: Double
    public var endTime: Double
    public var colorHex: String
    public var size: Double
    public var opacity: Double

    public init(
        startTime: Double,
        endTime: Double,
        colorHex: String = "#5B5CE2",
        size: Double = 1,
        opacity: Double = 1
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.colorHex = colorHex
        self.size = max(size, 0.01)
        self.opacity = min(max(opacity, 0), 1)
    }
}

public struct ClickDescription: Codable, Hashable, Sendable {
    public var text: String
    public var startTime: Double
    public var endTime: Double
    public var position: ClickDescriptionPosition
    public var x: Double
    public var y: Double
    public var style: TextOverlayStyle

    public init(
        text: String = "",
        startTime: Double,
        endTime: Double,
        position: ClickDescriptionPosition = .automatic,
        x: Double = 0.5,
        y: Double = 0.5,
        style: TextOverlayStyle = .default
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.position = position
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.style = style
    }
}

public struct CueSubtitle: Codable, Hashable, Sendable {
    public var text: String
    public var startTime: Double
    public var endTime: Double
    public var position: SubtitlePosition
    public var style: TextOverlayStyle

    public init(
        text: String = "",
        startTime: Double,
        endTime: Double,
        position: SubtitlePosition = .bottom,
        style: TextOverlayStyle = .default
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.position = position
        self.style = style
    }
}

public struct TimedPointerClick: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceTime: Double
    public var time: Double
    public var x: Double
    public var y: Double
    public var button: PointerButton
    public var indicator: ClickIndicatorStyle
    public var description: ClickDescription
    public var cueSubtitle: CueSubtitle
    public var sourceAnchor: ClickSourceAnchor?

    public init(
        id: UUID = UUID(),
        sourceTime: Double? = nil,
        time: Double,
        x: Double,
        y: Double,
        button: PointerButton = .left,
        caption: String = "",
        captionStyle: TextOverlayStyle = .default,
        sourceAnchor: ClickSourceAnchor? = nil
    ) {
        self.id = id
        self.sourceTime = max(sourceTime ?? time, 0)
        self.time = max(time, 0)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.button = button
        self.sourceAnchor = sourceAnchor
        let start = max(time - 0.15, 0)
        let end = time + 1.85
        self.indicator = ClickIndicatorStyle(
            startTime: start,
            endTime: end
        )
        self.description = ClickDescription(
            text: caption,
            startTime: start,
            endTime: end,
            style: captionStyle
        )
        self.cueSubtitle = CueSubtitle(
            startTime: start,
            endTime: end
        )
    }

    public var caption: String {
        get { description.text }
        set { description.text = newValue }
    }

    public var captionStyle: TextOverlayStyle {
        get { description.style }
        set { description.style = newValue }
    }

    public var isComplete: Bool {
        !description.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cueSubtitle.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clamps generated Click Cue windows only when the recording duration becomes known.
    public func bounded(to duration: Double) -> TimedPointerClick {
        var result = self
        let minimumEnd = min(max(time + 0.01, 0.01), duration)
        result.indicator.startTime = min(result.indicator.startTime, time)
        result.indicator.endTime = min(max(result.indicator.endTime, minimumEnd), duration)
        result.description.startTime = min(result.description.startTime, time)
        result.description.endTime = min(max(result.description.endTime, minimumEnd), duration)
        result.cueSubtitle.startTime = min(result.cueSubtitle.startTime, time)
        result.cueSubtitle.endTime = min(max(result.cueSubtitle.endTime, minimumEnd), duration)
        return result
    }
}

public struct ClickSourceAnchor: Codable, Hashable, Sendable {
    public var clipID: UUID
    public var clipKind: VideoClipKind
    public var clipOffset: Double

    public init(
        clipID: UUID,
        clipKind: VideoClipKind,
        clipOffset: Double
    ) {
        self.clipID = clipID
        self.clipKind = clipKind
        self.clipOffset = max(clipOffset, 0)
    }
}

public struct TimedSubtitle: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var text: String
    public var position: SubtitlePosition
    public var style: TextOverlayStyle

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        text: String = "",
        position: SubtitlePosition = .bottom,
        style: TextOverlayStyle = .default
    ) {
        self.id = id
        self.startTime = max(startTime, 0)
        self.endTime = max(endTime, self.startTime)
        self.text = text
        self.position = position
        self.style = style
    }
}

public struct SpotlightEffect: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var dimOpacity: Double
    public var sourceAnchor: ContentEffectAnchor?

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        dimOpacity: Double = 0.55,
        sourceAnchor: ContentEffectAnchor? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.dimOpacity = min(max(dimOpacity, 0), 1)
        self.sourceAnchor = sourceAnchor
    }
}

public struct PanZoomEffect: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var startX: Double
    public var startY: Double
    public var startScale: Double
    public var endX: Double
    public var endY: Double
    public var endScale: Double
    public var sourceAnchor: ContentEffectAnchor?

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        startX: Double = 0.5,
        startY: Double = 0.5,
        startScale: Double = 1,
        endX: Double,
        endY: Double,
        endScale: Double,
        sourceAnchor: ContentEffectAnchor? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startX = startX
        self.startY = startY
        self.startScale = startScale
        self.endX = endX
        self.endY = endY
        self.endScale = endScale
        self.sourceAnchor = sourceAnchor
    }
}

public struct ContentEffectAnchor: Codable, Hashable, Sendable {
    public var clipID: UUID
    public var clipKind: VideoClipKind
    public var sourceStart: Double
    public var sourceEnd: Double
    public var clipStartOffset: Double
    public var clipEndOffset: Double

    public init(
        clipID: UUID,
        clipKind: VideoClipKind,
        sourceStart: Double,
        sourceEnd: Double,
        clipStartOffset: Double,
        clipEndOffset: Double
    ) {
        self.clipID = clipID
        self.clipKind = clipKind
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.clipStartOffset = max(clipStartOffset, 0)
        self.clipEndOffset = max(clipEndOffset, self.clipStartOffset)
    }
}

public struct TitleCardEffect: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var title: String
    public var subtitle: String
    public var style: TextOverlayStyle

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        title: String,
        subtitle: String = "",
        style: TextOverlayStyle = .default
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.subtitle = subtitle
        self.style = style
    }
}

public struct CTACardEffect: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var title: String
    public var buttonLabel: String
    public var style: TextOverlayStyle

    public init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        title: String,
        buttonLabel: String,
        style: TextOverlayStyle = .default
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.buttonLabel = buttonLabel
        self.style = style
    }
}

public enum DemoEffect: Codable, Identifiable, Hashable, Sendable {
    case spotlight(SpotlightEffect)
    case panZoom(PanZoomEffect)
    case title(TitleCardEffect)
    case cta(CTACardEffect)

    public var id: UUID {
        switch self {
        case let .spotlight(value): value.id
        case let .panZoom(value): value.id
        case let .title(value): value.id
        case let .cta(value): value.id
        }
    }

    public var startTime: Double {
        switch self {
        case let .spotlight(value): value.startTime
        case let .panZoom(value): value.startTime
        case let .title(value): value.startTime
        case let .cta(value): value.startTime
        }
    }

    public var endTime: Double {
        switch self {
        case let .spotlight(value): value.endTime
        case let .panZoom(value): value.endTime
        case let .title(value): value.endTime
        case let .cta(value): value.endTime
        }
    }
}

public enum ClickSuggestionState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case applied
    case rejected
}

public struct ClickEditSuggestion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var clickID: UUID
    public var state: ClickSuggestionState
    public var splitTime: Double
    public var spotlight: SpotlightEffect
    public var panZoom: PanZoomEffect

    public init(
        id: UUID = UUID(),
        clickID: UUID,
        state: ClickSuggestionState = .pending,
        splitTime: Double,
        spotlight: SpotlightEffect,
        panZoom: PanZoomEffect
    ) {
        self.id = id
        self.clickID = clickID
        self.state = state
        self.splitTime = splitTime
        self.spotlight = spotlight
        self.panZoom = panZoom
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
    public var foregroundHex: String
    public var fontSize: Double
    public var backgroundOpacity: Double {
        didSet {
            backgroundOpacity = Self.clampedOpacity(backgroundOpacity)
        }
    }

    public init(
        backgroundHex: String = "#11131A",
        backgroundOpacity: Double = 0.72,
        foregroundHex: String = "#FFFFFF",
        fontSize: Double = 17
    ) {
        self.backgroundHex = backgroundHex
        self.backgroundOpacity = Self.clampedOpacity(backgroundOpacity)
        self.foregroundHex = foregroundHex
        self.fontSize = max(fontSize, 1)
    }

    public static let `default` = TextOverlayStyle()

    private enum CodingKeys: String, CodingKey {
        case backgroundHex
        case backgroundOpacity
        case foregroundHex
        case fontSize
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
        foregroundHex = try container.decodeIfPresent(
            String.self,
            forKey: .foregroundHex
        ) ?? Self.default.foregroundHex
        fontSize = max(
            try container.decodeIfPresent(Double.self, forKey: .fontSize)
                ?? Self.default.fontSize,
            1
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
