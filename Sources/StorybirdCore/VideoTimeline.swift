import Foundation

public enum VideoTimelineEditError: LocalizedError, Equatable {
    case clipNotFound
    case invalidSplit
    case invalidTrim
    case invalidSpeed
    case invalidFreeze
    case invalidDestination
    case invalidClickPlacement

    public var errorDescription: String? {
        switch self {
        case .clipNotFound: "The timeline clip does not exist."
        case .invalidSplit: "The split point must be inside the clip."
        case .invalidTrim: "The trimmed source range is invalid."
        case .invalidSpeed: "Playback speed must be between 0.25× and 4×."
        case .invalidFreeze: "A freeze duration must be greater than zero."
        case .invalidDestination: "The destination index is outside the timeline."
        case .invalidClickPlacement:
            "A Click Cue must use a playable video time and a position inside the frame."
        }
    }
}

public enum VideoTimelineEditor {
    /// Maps one edited project time back to the immutable recording time used for frame extraction.
    public static func sourceTime(
        in project: DemoProject,
        at projectTime: Double
    ) -> Double? {
        VideoTimelineSchedule(project: project).sourceTime(at: projectTime)
    }

    /// Adds one incomplete Click Cue at a playable project frame, preserving the
    /// source-time link needed for later trim, reorder, and speed remapping.
    public static func addClickCue(
        to project: DemoProject,
        at projectTime: Double,
        x: Double,
        y: Double
    ) throws -> DemoProject {
        let timelineDuration = project.timelineDuration
        guard projectTime.isFinite,
              projectTime >= 0,
              projectTime < timelineDuration,
              x.isFinite,
              y.isFinite,
              (0...1).contains(x),
              (0...1).contains(y),
              let location = VideoTimelineSchedule(
                  project: project
              ).sourceLocation(at: projectTime)
        else {
            throw VideoTimelineEditError.invalidClickPlacement
        }
        var result = project
        let click = TimedPointerClick(
            sourceTime: location.sourceTime,
            time: projectTime,
            x: x,
            y: y,
            sourceAnchor: ClickSourceAnchor(
                clipID: location.clipID,
                clipKind: location.clipKind,
                clipOffset: location.clipOffset
            )
        ).bounded(to: timelineDuration)
        result.clicks.append(click)
        result.clicks.sort { $0.time < $1.time }
        result.suggestions = ClickSuggestionGenerator.generate(for: result)
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Splits one source-backed clip while preserving one unambiguous owner for boundary cues.
    public static func split(
        project: DemoProject,
        clipID: UUID,
        sourceTime: Double
    ) throws -> DemoProject {
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        let clip = result.clips[index]
        guard clip.kind == .video,
              sourceTime > clip.sourceStart,
              sourceTime < clip.sourceEnd
        else {
            throw VideoTimelineEditError.invalidSplit
        }
        let left = VideoClip(
            sourceStart: clip.sourceStart,
            sourceEnd: sourceTime,
            playbackRate: clip.playbackRate
        )
        let right = VideoClip(
            sourceStart: sourceTime,
            sourceEnd: clip.sourceEnd,
            playbackRate: clip.playbackRate
        )
        result.clips.replaceSubrange(
            index...index,
            with: [left, right]
        )
        for clickIndex in result.clicks.indices
        where result.clicks[clickIndex].sourceAnchor?.clipID == clipID {
            let child = result.clicks[clickIndex].sourceTime < sourceTime
                ? left
                : right
            result.clicks[clickIndex].sourceAnchor = ClickSourceAnchor(
                clipID: child.id,
                clipKind: .video,
                clipOffset:
                    (result.clicks[clickIndex].sourceTime
                        - child.sourceStart) / child.playbackRate
            )
        }
        result.effects = result.effects.flatMap {
            transferEffect(
                $0,
                from: clipID,
                to: left,
                or: right
            )
        }
        return remapContentLayers(result)
    }

    /// Trims a video clip and removes content-linked layers outside every remaining source range.
    public static func trim(
        project: DemoProject,
        clipID: UUID,
        sourceStart: Double,
        sourceEnd: Double
    ) throws -> DemoProject {
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        let clip = result.clips[index]
        guard clip.kind == .video,
              sourceStart >= clip.sourceStart,
              sourceEnd <= clip.sourceEnd,
              sourceStart < sourceEnd
        else {
            throw VideoTimelineEditError.invalidTrim
        }
        result.clips[index].sourceStart = sourceStart
        result.clips[index].sourceEnd = sourceEnd
        return remapContentLayers(result)
    }

    /// Removes one clip without touching the immutable recording asset.
    public static func delete(
        project: DemoProject,
        clipID: UUID
    ) throws -> DemoProject {
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        result.clips.remove(at: index)
        return remapContentLayers(result)
    }

    /// Reorders one clip and remaps source-linked cues onto the resulting project clock.
    public static func move(
        project: DemoProject,
        clipID: UUID,
        destination: Int
    ) throws -> DemoProject {
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        guard (0...result.clips.count).contains(destination) else {
            throw VideoTimelineEditError.invalidDestination
        }
        let clip = result.clips.remove(at: index)
        result.clips.insert(clip, at: min(destination, result.clips.count))
        return remapContentLayers(result)
    }

    /// Applies the approved 0.25×...4× speed range and keeps linked layers on the same content.
    public static func setSpeed(
        project: DemoProject,
        clipID: UUID,
        rate: Double
    ) throws -> DemoProject {
        guard (0.25...4).contains(rate) else {
            throw VideoTimelineEditError.invalidSpeed
        }
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        result.clips[index].playbackRate = rate
        return remapContentLayers(result)
    }

    /// Inserts a still-frame segment after the chosen clip while preserving the original video.
    public static func insertFreeze(
        project: DemoProject,
        after clipID: UUID,
        sourceTime: Double,
        duration: Double
    ) throws -> DemoProject {
        guard duration > 0 else {
            throw VideoTimelineEditError.invalidFreeze
        }
        var result = project
        guard let index = result.clips.firstIndex(where: { $0.id == clipID }) else {
            throw VideoTimelineEditError.clipNotFound
        }
        result.clips.insert(
            VideoClip(
                kind: .freeze,
                sourceStart: sourceTime,
                sourceEnd: sourceTime,
                freezeDuration: duration
            ),
            at: index + 1
        )
        return remapContentLayers(result)
    }

    /// Remaps anchored Click Cues only through their exact owning clip; split
    /// transfers anchors before this pass, while legacy unanchored Cues use source time.
    public static func remapContentLayers(_ project: DemoProject) -> DemoProject {
        var result = project
        let schedule = VideoTimelineSchedule(project: result)
        let mappedClicks = result.clicks.compactMap {
            remappedClick($0, in: schedule)
        }
        let timelineDuration = result.timelineDuration
        result.clicks = mappedClicks.map {
            boundedClickWindows($0, timelineDuration: timelineDuration)
        }.sorted { $0.time < $1.time }
        result.effects = result.effects.compactMap {
            remappedEffect($0, in: schedule)
        }
        let clickByID = Dictionary(
            uniqueKeysWithValues: result.clicks.map { ($0.id, $0) }
        )
        result.suggestions = result.suggestions.compactMap { suggestion in
            guard let click = clickByID[suggestion.clickID] else {
                return nil
            }
            guard suggestion.state == .pending else { return suggestion }
            var moved = suggestion
            let offset = click.time - suggestion.splitTime
            moved.splitTime = click.time
            moved.spotlight.startTime += offset
            moved.spotlight.endTime += offset
            moved.panZoom.startTime += offset
            moved.panZoom.endTime += offset
            return moved
        }
        return result
    }

    /// Anchors a spotlight or pan/zoom draft to the clip visible at one project time.
    public static func anchorContentEffect(
        _ effect: DemoEffect,
        in project: DemoProject,
        at projectTime: Double
    ) -> DemoEffect {
        let schedule = VideoTimelineSchedule(project: project)
        let scheduledClips: [
            VideoTimelineSchedule.ScheduledClip
        ] = schedule.items.compactMap {
            guard case let .clip(value) = $0 else { return nil }
            return value
        }
        guard let location = schedule.sourceLocation(at: projectTime),
              let scheduled = scheduledClips.first(
                  where: { $0.clip.id == location.clipID }
              )
        else {
            return effect
        }
        let startOffset = max(effect.startTime - scheduled.projectStart, 0)
        let endOffset = min(
            max(effect.endTime - scheduled.projectStart, startOffset),
            scheduled.clip.outputDuration
        )
        let anchor: ContentEffectAnchor
        switch scheduled.clip.kind {
        case .video:
            anchor = ContentEffectAnchor(
                clipID: scheduled.clip.id,
                clipKind: .video,
                sourceStart: scheduled.clip.sourceStart
                    + startOffset * scheduled.clip.playbackRate,
                sourceEnd: scheduled.clip.sourceStart
                    + endOffset * scheduled.clip.playbackRate,
                clipStartOffset: startOffset,
                clipEndOffset: endOffset
            )
        case .freeze:
            anchor = ContentEffectAnchor(
                clipID: scheduled.clip.id,
                clipKind: .freeze,
                sourceStart: scheduled.clip.sourceStart,
                sourceEnd: scheduled.clip.sourceStart,
                clipStartOffset: startOffset,
                clipEndOffset: endOffset
            )
        }
        return effectWithAnchor(effect, anchor)
    }

    /// Rebuilds content anchors only for effects whose editable project-time bounds
    /// changed, preserving style edits and rejecting ranges without a playable owner.
    public static func reanchorChangedContentEffectTimes(
        from current: DemoProject,
        to draft: DemoProject
    ) -> DemoProject {
        var result = draft
        let currentByID = Dictionary(
            uniqueKeysWithValues: current.effects.map { ($0.id, $0) }
        )
        result.effects = result.effects.map { effect in
            guard let previous = currentByID[effect.id],
                  let previousAnchor = effectAnchor(previous),
                  abs(previous.startTime - effect.startTime) > 0.000_001
                    || abs(previous.endTime - effect.endTime) > 0.000_001
            else {
                return effect
            }
            guard effect.startTime.isFinite,
                  effect.endTime.isFinite,
                  effect.startTime >= 0,
                  effect.startTime < effect.endTime,
                  effect.endTime <= result.timelineDuration
            else {
                return effectWithTimesAndAnchor(
                    effect,
                    previous.startTime,
                    previous.endTime,
                    previousAnchor
                )
            }
            let schedule = VideoTimelineSchedule(project: result)
            let endProbe = max(
                effect.startTime,
                effect.endTime - 0.000_001
            )
            guard let startLocation = schedule.sourceLocation(
                at: effect.startTime
            ),
                let endLocation = schedule.sourceLocation(at: endProbe),
                startLocation.clipID == endLocation.clipID
            else {
                return effectWithTimesAndAnchor(
                    effect,
                    previous.startTime,
                    previous.endTime,
                    previousAnchor
                )
            }
            let anchorTime = min(
                max(
                    (effect.startTime + effect.endTime) / 2,
                    0
                ),
                max(result.timelineDuration - 0.000_001, 0)
            )
            let reanchored = anchorContentEffect(
                effect,
                in: result,
                at: anchorTime
            )
            guard effectAnchor(reanchored) != nil,
                  abs(reanchored.startTime - effect.startTime) <= 0.000_001,
                  abs(reanchored.endTime - effect.endTime) <= 0.000_001
            else {
                return effectWithTimesAndAnchor(
                    effect,
                    previous.startTime,
                    previous.endTime,
                    previousAnchor
                )
            }
            return reanchored
        }
        return result
    }

    /// Resolves anchored Cues against their exact owner and removes them when that
    /// owner is gone; source-time adoption is reserved for legacy unanchored Cues.
    private static func remappedClick(
        _ click: TimedPointerClick,
        in schedule: VideoTimelineSchedule
    ) -> TimedPointerClick? {
        let scheduledClips: [
            VideoTimelineSchedule.ScheduledClip
        ] = schedule.items.compactMap {
            guard case let .clip(value) = $0 else { return nil }
            return value
        }
        let scheduled: VideoTimelineSchedule.ScheduledClip?
        if let anchor = click.sourceAnchor,
           let exact = scheduledClips.first(
               where: { $0.clip.id == anchor.clipID }
           ) {
            guard exact.clip.kind == anchor.clipKind else {
                return nil
            }
            switch exact.clip.kind {
            case .video:
                guard click.sourceTime >= exact.clip.sourceStart,
                      click.sourceTime < exact.clip.sourceEnd
                else {
                    return nil
                }
            case .freeze:
                guard anchor.clipOffset < exact.clip.outputDuration else {
                    return nil
                }
            }
            scheduled = exact
        } else if click.sourceAnchor == nil {
            scheduled = scheduledClips.first {
                $0.clip.kind == VideoClipKind.video
                    && click.sourceTime >= $0.clip.sourceStart
                    && click.sourceTime < $0.clip.sourceEnd
            }
        } else {
            scheduled = nil
        }
        guard let scheduled else { return nil }

        var mapped = click
        let newTime: Double
        switch scheduled.clip.kind {
        case .video:
            newTime = scheduled.projectStart
                + (click.sourceTime - scheduled.clip.sourceStart)
                    / scheduled.clip.playbackRate
        case .freeze:
            newTime = scheduled.projectStart
                + (click.sourceAnchor?.clipOffset ?? 0)
        }
        let offset = newTime - click.time
        mapped.time = newTime
        mapped.indicator.startTime += offset
        mapped.indicator.endTime += offset
        mapped.description.startTime += offset
        mapped.description.endTime += offset
        mapped.cueSubtitle.startTime += offset
        mapped.cueSubtitle.endTime += offset
        mapped.sourceAnchor = ClickSourceAnchor(
            clipID: scheduled.clip.id,
            clipKind: scheduled.clip.kind,
            clipOffset: newTime - scheduled.projectStart
        )
        return mapped
    }

    /// Maps one anchored content effect through its exact clip, clipping trimmed
    /// source ranges and dropping effects whose owning clip was removed.
    private static func remappedEffect(
        _ effect: DemoEffect,
        in schedule: VideoTimelineSchedule
    ) -> DemoEffect? {
        guard let anchor = effectAnchor(effect) else { return effect }
        let scheduled: VideoTimelineSchedule.ScheduledClip? =
            schedule.items.compactMap {
                guard case let .clip(value) = $0 else { return nil }
                return value
            }.first { $0.clip.id == anchor.clipID }
        guard let scheduled, scheduled.clip.kind == anchor.clipKind else {
            return nil
        }
        var updated = anchor
        let start: Double
        let end: Double
        switch scheduled.clip.kind {
        case .video:
            updated.sourceStart = max(anchor.sourceStart, scheduled.clip.sourceStart)
            updated.sourceEnd = min(anchor.sourceEnd, scheduled.clip.sourceEnd)
            guard updated.sourceStart < updated.sourceEnd else { return nil }
            start = scheduled.projectStart
                + (updated.sourceStart - scheduled.clip.sourceStart)
                    / scheduled.clip.playbackRate
            end = scheduled.projectStart
                + (updated.sourceEnd - scheduled.clip.sourceStart)
                    / scheduled.clip.playbackRate
        case .freeze:
            updated.clipStartOffset = min(
                anchor.clipStartOffset,
                scheduled.clip.outputDuration
            )
            updated.clipEndOffset = min(
                anchor.clipEndOffset,
                scheduled.clip.outputDuration
            )
            guard updated.clipStartOffset < updated.clipEndOffset else { return nil }
            start = scheduled.projectStart + updated.clipStartOffset
            end = scheduled.projectStart + updated.clipEndOffset
        }
        return effectWithTimesAndAnchor(effect, start, end, updated)
    }

    /// Partitions an anchored video effect across zero, one, or two split children,
    /// assigning a distinct ID when both child-owned source intervals remain.
    private static func transferEffect(
        _ effect: DemoEffect,
        from oldClipID: UUID,
        to left: VideoClip,
        or right: VideoClip
    ) -> [DemoEffect] {
        guard let anchor = effectAnchor(effect),
              anchor.clipID == oldClipID,
              anchor.clipKind == .video else {
            return [effect]
        }
        let leftStart = max(anchor.sourceStart, left.sourceStart)
        let leftEnd = min(anchor.sourceEnd, left.sourceEnd)
        let rightStart = max(anchor.sourceStart, right.sourceStart)
        let rightEnd = min(anchor.sourceEnd, right.sourceEnd)
        var transferred: [DemoEffect] = []
        if leftStart < leftEnd {
            var leftAnchor = anchor
            leftAnchor.clipID = left.id
            leftAnchor.sourceStart = leftStart
            leftAnchor.sourceEnd = leftEnd
            transferred.append(effectWithAnchor(effect, leftAnchor))
        }
        if rightStart < rightEnd {
            var rightAnchor = anchor
            rightAnchor.clipID = right.id
            rightAnchor.sourceStart = rightStart
            rightAnchor.sourceEnd = rightEnd
            let rightEffect = transferred.isEmpty
                ? effect
                : reidentifiedEffect(effect)
            transferred.append(effectWithAnchor(rightEffect, rightAnchor))
        }
        return transferred
    }

    /// Reads content ownership only from spotlight and pan/zoom effects; full-screen
    /// title and CTA cards remain project-time anchored.
    private static func effectAnchor(
        _ effect: DemoEffect
    ) -> ContentEffectAnchor? {
        switch effect {
        case let .spotlight(value): value.sourceAnchor
        case let .panZoom(value): value.sourceAnchor
        case .title, .cta: nil
        }
    }

    /// Replaces one content effect's ownership metadata without changing its
    /// current project-time interval or visual properties.
    private static func effectWithAnchor(
        _ effect: DemoEffect,
        _ anchor: ContentEffectAnchor
    ) -> DemoEffect {
        switch effect {
        case var .spotlight(value):
            value.sourceAnchor = anchor
            return .spotlight(value)
        case var .panZoom(value):
            value.sourceAnchor = anchor
            return .panZoom(value)
        case .title, .cta:
            return effect
        }
    }

    /// Gives a split-off effect segment a distinct identity while preserving every
    /// visual property and its current project-time interval.
    private static func reidentifiedEffect(
        _ effect: DemoEffect
    ) -> DemoEffect {
        switch effect {
        case var .spotlight(value):
            value.id = UUID()
            return .spotlight(value)
        case var .panZoom(value):
            value.id = UUID()
            return .panZoom(value)
        case .title, .cta:
            return effect
        }
    }

    /// Applies a remapped project-time interval and matching ownership metadata
    /// while preserving the effect's visual properties and identifier.
    private static func effectWithTimesAndAnchor(
        _ effect: DemoEffect,
        _ start: Double,
        _ end: Double,
        _ anchor: ContentEffectAnchor
    ) -> DemoEffect {
        switch effect {
        case var .spotlight(value):
            value.startTime = start
            value.endTime = end
            value.sourceAnchor = anchor
            return .spotlight(value)
        case var .panZoom(value):
            value.startTime = start
            value.endTime = end
            value.sourceAnchor = anchor
            return .panZoom(value)
        case .title, .cta:
            return effect
        }
    }

    /// Keeps all remapped Click Cue windows valid when an edit shortens the output timeline.
    private static func boundedClickWindows(
        _ click: TimedPointerClick,
        timelineDuration: Double
    ) -> TimedPointerClick {
        var result = click
        let minimumEnd = min(
            max(click.time + 0.001, 0.001),
            timelineDuration
        )
        result.indicator.startTime = min(
            max(result.indicator.startTime, 0),
            click.time
        )
        result.indicator.endTime = min(
            max(result.indicator.endTime, minimumEnd),
            timelineDuration
        )
        result.description.startTime = min(
            max(result.description.startTime, 0),
            click.time
        )
        result.description.endTime = min(
            max(result.description.endTime, minimumEnd),
            timelineDuration
        )
        result.cueSubtitle.startTime = min(
            max(result.cueSubtitle.startTime, 0),
            click.time
        )
        result.cueSubtitle.endTime = min(
            max(result.cueSubtitle.endTime, minimumEnd),
            timelineDuration
        )
        return result
    }
}

public enum DemoEffectEditError: LocalizedError, Equatable {
    case clipNotFound
    case ctaAlreadyExists
    case effectNotFound
    case invalidTitlePosition

    public var errorDescription: String? {
        switch self {
        case .clipNotFound: "The card insertion clip does not exist."
        case .ctaAlreadyExists: "The project already has a CTA card."
        case .effectNotFound: "The effect does not exist."
        case .invalidTitlePosition:
            "A title card must be at the start or between video clips."
        }
    }
}

public enum DemoEffectEditor {
    /// Inserts a full-screen title at the start or after one clip and shifts all later project-time layers.
    public static func insertTitle(
        in project: DemoProject,
        after clipID: UUID?,
        duration: Double = 1,
        title: String = "Title"
    ) throws -> DemoProject {
        if let clipID,
           project.clips.last?.id == clipID {
            throw DemoEffectEditError.invalidTitlePosition
        }
        let insertion = try insertionTime(in: project, after: clipID)
        var result = shiftProjectTimes(
            in: project,
            from: insertion,
            by: duration
        )
        result.effects.append(
            .title(
                TitleCardEffect(
                    startTime: insertion,
                    endTime: insertion + duration,
                    title: title
                )
            )
        )
        return result
    }

    /// Appends the single non-interactive CTA after every clip and existing title card.
    public static func insertCTA(
        in project: DemoProject,
        duration: Double = 1,
        title: String = "Next step",
        buttonLabel: String = "Learn more"
    ) throws -> DemoProject {
        guard !project.effects.contains(where: {
            if case .cta = $0 { return true }
            return false
        }) else {
            throw DemoEffectEditError.ctaAlreadyExists
        }
        var result = project
        let start = project.timelineDuration
        result.effects.append(
            .cta(
                CTACardEffect(
                    startTime: start,
                    endTime: start + duration,
                    title: title,
                    buttonLabel: buttonLabel
                )
            )
        )
        return result
    }

    /// Deletes one effect and closes the timeline gap only for full-screen card segments.
    public static func delete(
        _ effectID: UUID,
        from project: DemoProject
    ) throws -> DemoProject {
        guard let effect = project.effects.first(
            where: { $0.id == effectID }
        ) else {
            throw DemoEffectEditError.effectNotFound
        }
        var result = project
        result.effects.removeAll { $0.id == effectID }
        switch effect {
        case .title, .cta:
            return shiftProjectTimes(
                in: result,
                from: effect.endTime,
                by: -(effect.endTime - effect.startTime)
            )
        case .spotlight, .panZoom:
            return result
        }
    }

    private static func insertionTime(
        in project: DemoProject,
        after clipID: UUID?
    ) throws -> Double {
        guard let insertion = VideoTimelineSchedule(
            project: project
        ).insertionTime(after: clipID) else {
            throw DemoEffectEditError.clipNotFound
        }
        return insertion
    }

    private static func shiftProjectTimes(
        in project: DemoProject,
        from threshold: Double,
        by delta: Double
    ) -> DemoProject {
        var result = project
        for index in result.clicks.indices
        where result.clicks[index].time >= threshold {
            result.clicks[index].time += delta
            result.clicks[index].indicator.startTime += delta
            result.clicks[index].indicator.endTime += delta
            result.clicks[index].description.startTime += delta
            result.clicks[index].description.endTime += delta
            result.clicks[index].cueSubtitle.startTime += delta
            result.clicks[index].cueSubtitle.endTime += delta
        }
        for index in result.subtitles.indices
        where result.subtitles[index].startTime >= threshold {
            result.subtitles[index].startTime += delta
            result.subtitles[index].endTime += delta
        }
        result.effects = result.effects.map {
            shift(effect: $0, from: threshold, by: delta)
        }
        for index in result.suggestions.indices
        where result.suggestions[index].splitTime >= threshold {
            result.suggestions[index].splitTime += delta
            result.suggestions[index].spotlight.startTime += delta
            result.suggestions[index].spotlight.endTime += delta
            result.suggestions[index].panZoom.startTime += delta
            result.suggestions[index].panZoom.endTime += delta
        }
        return result
    }

    private static func shift(
        effect: DemoEffect,
        from threshold: Double,
        by delta: Double
    ) -> DemoEffect {
        guard effect.startTime >= threshold else { return effect }
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

public enum ClickSuggestionError: LocalizedError, Equatable {
    case suggestionNotFound
    case suggestionNotPending
    case clickNotFound

    public var errorDescription: String? {
        switch self {
        case .suggestionNotFound: "The edit suggestion does not exist."
        case .suggestionNotPending: "Only a pending suggestion can change state."
        case .clickNotFound: "The suggestion's Click Cue does not exist."
        }
    }
}

public enum ClickSuggestionGenerator {
    /// Produces one deterministic pending suggestion per Click Cue without changing output layers.
    public static func generate(for project: DemoProject) -> [ClickEditSuggestion] {
        let existing = Dictionary(
            uniqueKeysWithValues: project.suggestions.map { ($0.clickID, $0) }
        )
        return project.clicks.map { click in
            if let current = existing[click.id], current.state != .pending {
                return current
            }
            let start = max(click.time - 0.25, 0)
            let end = min(click.time + 1.25, project.timelineDuration)
            let spotlight = SpotlightEffect(
                id: existing[click.id]?.spotlight.id ?? UUID(),
                startTime: start,
                endTime: max(end, start + 0.01),
                x: max(click.x - 0.12, 0),
                y: max(click.y - 0.08, 0),
                width: min(0.24, 1 - max(click.x - 0.12, 0)),
                height: min(0.16, 1 - max(click.y - 0.08, 0))
            )
            let panZoom = PanZoomEffect(
                id: existing[click.id]?.panZoom.id ?? UUID(),
                startTime: start,
                endTime: max(end, start + 0.01),
                endX: click.x,
                endY: click.y,
                endScale: 1.5
            )
            let anchoredSpotlight = VideoTimelineEditor.anchorContentEffect(
                .spotlight(spotlight),
                in: project,
                at: click.time
            )
            let anchoredPanZoom = VideoTimelineEditor.anchorContentEffect(
                .panZoom(panZoom),
                in: project,
                at: click.time
            )
            guard case let .spotlight(spotlightValue) = anchoredSpotlight,
                  case let .panZoom(panZoomValue) = anchoredPanZoom
            else {
                return existing[click.id] ?? ClickEditSuggestion(
                    clickID: click.id,
                    splitTime: click.time,
                    spotlight: spotlight,
                    panZoom: panZoom
                )
            }
            return ClickEditSuggestion(
                id: existing[click.id]?.id ?? UUID(),
                clickID: click.id,
                splitTime: click.time,
                spotlight: spotlightValue,
                panZoom: panZoomValue
            )
        }
    }

    /// Applies one complete suggestion bundle as an atomic project draft for validation and persistence.
    public static func apply(
        _ suggestionID: UUID,
        to project: DemoProject
    ) throws -> DemoProject {
        var result = project
        guard let suggestionIndex = result.suggestions.firstIndex(
            where: { $0.id == suggestionID }
        ) else {
            throw ClickSuggestionError.suggestionNotFound
        }
        let suggestion = result.suggestions[suggestionIndex]
        guard suggestion.state == .pending else {
            throw ClickSuggestionError.suggestionNotPending
        }
        guard let click = result.clicks.first(
            where: { $0.id == suggestion.clickID }
        ) else {
            throw ClickSuggestionError.clickNotFound
        }
        if click.sourceAnchor?.clipKind != .freeze,
           let clip = result.clips.first(where: {
            $0.kind == .video
                && click.sourceTime > $0.sourceStart
                && click.sourceTime < $0.sourceEnd
        }) {
            result = try VideoTimelineEditor.split(
                project: result,
                clipID: clip.id,
                sourceTime: click.sourceTime
            )
        }
        let currentClick = result.clicks.first {
            $0.id == suggestion.clickID
        } ?? click
        let spotlight = VideoTimelineEditor.anchorContentEffect(
            DemoEffect.spotlight(suggestion.spotlight),
            in: result,
            at: currentClick.time
        )
        let panZoom = VideoTimelineEditor.anchorContentEffect(
            DemoEffect.panZoom(suggestion.panZoom),
            in: result,
            at: currentClick.time
        )
        result.effects.append(spotlight)
        result.effects.append(panZoom)
        guard let remappedIndex = result.suggestions.firstIndex(
            where: { $0.id == suggestionID }
        ) else {
            throw ClickSuggestionError.suggestionNotFound
        }
        result.suggestions[remappedIndex].state = .applied
        if case let .spotlight(value) = spotlight {
            result.suggestions[remappedIndex].spotlight = value
        }
        if case let .panZoom(value) = panZoom {
            result.suggestions[remappedIndex].panZoom = value
        }
        return VideoTimelineEditor.remapContentLayers(result)
    }

    /// Rejects one pending suggestion without changing output clips or effects.
    public static func reject(
        _ suggestionID: UUID,
        in project: DemoProject
    ) throws -> DemoProject {
        var result = project
        guard let index = result.suggestions.firstIndex(
            where: { $0.id == suggestionID }
        ) else {
            throw ClickSuggestionError.suggestionNotFound
        }
        guard result.suggestions[index].state == .pending else {
            throw ClickSuggestionError.suggestionNotPending
        }
        result.suggestions[index].state = .rejected
        return result
    }
}
