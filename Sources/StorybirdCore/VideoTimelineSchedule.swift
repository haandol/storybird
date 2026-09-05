import Foundation

public struct VideoTimelineSchedule: Sendable {
    public struct ScheduledClip: Sendable {
        public let clip: VideoClip
        public let projectStart: Double
        public let projectEnd: Double
    }

    public struct ScheduledCard: Sendable {
        public let effect: DemoEffect
        public let projectStart: Double
        public let projectEnd: Double
        public let sourceFrameTime: Double
    }

    public enum Item: Sendable {
        case clip(ScheduledClip)
        case card(ScheduledCard)

        public var projectStart: Double {
            switch self {
            case let .clip(value):
                value.projectStart
            case let .card(value):
                value.projectStart
            }
        }

        public var projectEnd: Double {
            switch self {
            case let .clip(value):
                value.projectEnd
            case let .card(value):
                value.projectEnd
            }
        }
    }

    public let items: [Item]
    public let duration: Double
    public let isStructurallyValid: Bool

    /// Creates the canonical clip/card order interpreted by validation, preview, and export.
    public init(project: DemoProject) {
        let cards = project.effects.filter(\.isFullScreenCard)
            .sorted { $0.startTime < $1.startTime }
        let ctaCount = cards.filter(\.isCTA).count
        var builtItems: [Item] = []
        var cursor = 0.0
        var cardIndex = 0
        var isValid = ctaCount <= 1

        for clip in project.clips {
            while cardIndex < cards.count,
                  Self.matches(cards[cardIndex].startTime, cursor) {
                let card = cards[cardIndex]
                guard !card.isCTA else {
                    isValid = false
                    break
                }
                builtItems.append(
                    .card(
                        ScheduledCard(
                            effect: card,
                            projectStart: cursor,
                            projectEnd: card.endTime,
                            sourceFrameTime: clip.sourceStart
                        )
                    )
                )
                cursor = card.endTime
                cardIndex += 1
            }
            guard isValid else { break }
            let end = cursor + clip.outputDuration
            builtItems.append(
                .clip(
                    ScheduledClip(
                        clip: clip,
                        projectStart: cursor,
                        projectEnd: end
                    )
                )
            )
            cursor = end
        }

        if isValid {
            while cardIndex < cards.count {
                let card = cards[cardIndex]
                guard Self.matches(card.startTime, cursor),
                      card.isCTA
                else {
                    isValid = false
                    break
                }
                builtItems.append(
                    .card(
                        ScheduledCard(
                            effect: card,
                            projectStart: cursor,
                            projectEnd: card.endTime,
                            sourceFrameTime:
                                project.recording?.duration ?? 0
                        )
                    )
                )
                cursor = card.endTime
                cardIndex += 1
            }
        }

        items = builtItems
        duration = cursor
        isStructurallyValid =
            isValid
                && cardIndex == cards.count
                && Self.matches(cursor, project.timelineDuration)
    }

    /// Maps project time to the immutable source frame, returning nil for full-screen cards.
    public func sourceTime(at projectTime: Double) -> Double? {
        guard projectTime >= 0 else { return nil }
        for item in items {
            switch item {
            case let .card(card):
                if projectTime >= card.projectStart,
                   projectTime < card.projectEnd {
                    return nil
                }
            case let .clip(clip):
                let isFinalEndpoint =
                    Self.matches(projectTime, duration)
                        && Self.matches(clip.projectEnd, duration)
                guard projectTime >= clip.projectStart,
                      projectTime < clip.projectEnd || isFinalEndpoint
                else {
                    continue
                }
                switch clip.clip.kind {
                case .video:
                    return clip.clip.sourceStart
                        + (projectTime - clip.projectStart)
                            * clip.clip.playbackRate
                case .freeze:
                    return clip.clip.sourceStart
                }
            }
        }
        return nil
    }

    /// Returns the boundary after a clip and any existing cards attached to that boundary.
    public func insertionTime(after clipID: UUID?) -> Double? {
        guard let clipID else { return 0 }
        guard let clipIndex = items.firstIndex(where: {
            if case let .clip(value) = $0 {
                return value.clip.id == clipID
            }
            return false
        }) else {
            return nil
        }
        var insertion = items[clipIndex].projectEnd
        for item in items.dropFirst(clipIndex + 1) {
            guard case let .card(card) = item,
                  Self.matches(card.projectStart, insertion)
            else {
                break
            }
            insertion = card.projectEnd
        }
        return insertion
    }

    private static func matches(
        _ lhs: Double,
        _ rhs: Double
    ) -> Bool {
        abs(lhs - rhs) <= 0.001
    }
}

public extension DemoEffect {
    var isFullScreenCard: Bool {
        switch self {
        case .title, .cta:
            true
        case .spotlight, .panZoom:
            false
        }
    }

    var isCTA: Bool {
        if case .cta = self {
            return true
        }
        return false
    }
}
