import Foundation

public enum TimelineLayerTarget: Hashable, Sendable {
    case click(UUID)
    case subtitle(UUID)
    case narration(UUID)
    case effect(UUID)
}

public enum TimelineLayerMoveError: LocalizedError {
    case layerNotFound
    case invalidMove

    public var errorDescription: String? {
        switch self {
        case .layerNotFound: "The selected layer no longer exists."
        case .invalidMove: "Keep the entire layer inside the project and a valid scene."
        }
    }
}

public enum TimelineLayerEditor {
    /// Translates one complete layer without trimming it. New scene ownership,
    /// effect conflicts, and project bounds are validated before any publication.
    public static func move(
        _ target: TimelineLayerTarget, by delta: Double, in project: DemoProject
    ) throws -> DemoProject {
        guard delta.isFinite else { throw TimelineLayerMoveError.invalidMove }
        var result = project
        switch target {
        case let .click(id):
            guard let index = result.clicks.firstIndex(where: { $0.id == id }) else {
                throw TimelineLayerMoveError.layerNotFound
            }
            var click = result.clicks[index]
            click.time += delta
            guard let location = VideoTimelineSchedule(project: project).sourceLocation(at: click.time) else {
                throw VideoTimelineEditError.invalidClickPlacement
            }
            click.sourceTime = location.sourceTime
            click.sourceAnchor = ClickSourceAnchor(
                clipID: location.clipID, clipKind: location.clipKind, clipOffset: location.clipOffset
            )
            click.indicator.startTime += delta
            click.indicator.endTime += delta
            click.description.startTime += delta
            click.description.endTime += delta
            click.cueSubtitle.startTime += delta
            click.cueSubtitle.endTime += delta
            guard min(click.indicator.startTime, click.description.startTime, click.cueSubtitle.startTime) >= 0,
                  max(click.indicator.endTime, click.description.endTime, click.cueSubtitle.endTime)
                    <= project.timelineDuration else {
                throw TimelineLayerMoveError.invalidMove
            }
            result.clicks[index] = click
            result.clicks.sort { $0.time < $1.time }
            for index in result.suggestions.indices
            where result.suggestions[index].clickID == id && result.suggestions[index].state == .pending {
                result.suggestions[index].splitTime += delta
                result.suggestions[index].spotlight.startTime += delta
                result.suggestions[index].spotlight.endTime += delta
                result.suggestions[index].panZoom.startTime += delta
                result.suggestions[index].panZoom.endTime += delta
            }
        case let .subtitle(id):
            guard let index = result.subtitles.firstIndex(where: { $0.id == id }) else {
                throw TimelineLayerMoveError.layerNotFound
            }
            result.subtitles[index].startTime += delta
            result.subtitles[index].endTime += delta
            if result.subtitles[index].sceneAnchor != nil {
                result.subtitles[index].sceneAnchor = try SceneTiming.anchor(
                    at: result.subtitles[index].startTime, in: project
                )
            }
        case let .narration(id):
            guard var layer = result.narrations.first(where: { $0.id == id }) else {
                throw TimelineLayerMoveError.layerNotFound
            }
            layer.startTime += delta
            return try AudioLayerEditor.replace(layer, in: project)
        case let .effect(id):
            guard let index = result.effects.firstIndex(where: { $0.id == id }) else {
                throw TimelineLayerMoveError.layerNotFound
            }
            let moved = translated(result.effects[index], by: delta)
            if moved.isFullScreenCard {
                return try DemoEffectEditor.replaceCard(moved, in: project)
            }
            let schedule = VideoTimelineSchedule(project: project)
            guard moved.startTime >= 0, moved.endTime <= project.timelineDuration,
                  let start = schedule.sourceLocation(at: moved.startTime),
                  let end = schedule.sourceLocation(at: max(moved.startTime, moved.endTime - 0.000_001)),
                  start.clipID == end.clipID else {
                throw TimelineLayerMoveError.invalidMove
            }
            result.effects[index] = VideoTimelineEditor.anchorContentEffect(
                moved, in: project, at: moved.startTime
            )
        }
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Moves every effect kind by the same amount while preserving its style
    /// and duration; card and content ownership are resolved by the caller.
    private static func translated(_ effect: DemoEffect, by delta: Double) -> DemoEffect {
        switch effect {
        case var .spotlight(value):
            value.startTime += delta
            value.endTime += delta
            return .spotlight(value)
        case var .panZoom(value):
            value.startTime += delta
            value.endTime += delta
            return .panZoom(value)
        case var .title(value):
            value.startTime += delta
            value.endTime += delta
            return .title(value)
        case var .cta(value):
            value.startTime += delta
            value.endTime += delta
            return .cta(value)
        }
    }
}
