import Foundation

public enum ClickCueEditor {
    /// A time property edit preserves the supplied component windows. Whole-group
    /// dragging is a separate operation; it must not be inferred from this value change.
    public static func reanchorTime(
        _ click: TimedPointerClick, in project: DemoProject
    ) throws -> TimedPointerClick {
        let windows = [
            (click.indicator.startTime, click.indicator.endTime),
            (click.description.startTime, click.description.endTime),
            (click.cueSubtitle.startTime, click.cueSubtitle.endTime)
        ]
        guard click.time.isFinite,
              windows.allSatisfy({
                  $0.0.isFinite && $0.1.isFinite && $0.0 >= 0
                      && $0.0 <= click.time && click.time < $0.1
                      && $0.1 <= project.timelineDuration
              }),
              let location = VideoTimelineSchedule(project: project).sourceLocation(at: click.time)
        else { throw VideoProjectValidationError.invalidClick(click.id) }
        var result = click
        result.sourceTime = location.sourceTime
        result.sourceAnchor = ClickSourceAnchor(
            clipID: location.clipID, clipKind: location.clipKind, clipOffset: location.clipOffset
        )
        return result
    }

    /// Reanchors native property edits before clip remapping so the old source
    /// anchor cannot silently overwrite a user's newly entered project time.
    public static func reconcileTimeEdits(
        from original: DemoProject, to edited: DemoProject
    ) throws -> DemoProject {
        var result = edited
        for index in result.clicks.indices {
            let click = result.clicks[index]
            if let previous = original.clicks.first(where: { $0.id == click.id }),
               previous.time != click.time {
                result.clicks[index] = try reanchorTime(click, in: result)
            }
        }
        result.clicks.sort { $0.time < $1.time }
        return result
    }
}
