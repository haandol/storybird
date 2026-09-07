import Foundation

public enum VideoTimelineEditError: LocalizedError, Equatable {
    case clipNotFound
    case invalidSplit
    case invalidTrim
    case invalidSpeed
    case invalidFreeze
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .clipNotFound: "The timeline clip does not exist."
        case .invalidSplit: "The split point must be inside the clip."
        case .invalidTrim: "The trimmed source range is invalid."
        case .invalidSpeed: "Playback speed must be between 0.25× and 4×."
        case .invalidFreeze: "A freeze duration must be greater than zero."
        case .invalidDestination: "The destination index is outside the timeline."
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
        result.clips.replaceSubrange(
            index...index,
            with: [
                VideoClip(
                    sourceStart: clip.sourceStart,
                    sourceEnd: sourceTime,
                    playbackRate: clip.playbackRate
                ),
                VideoClip(
                    sourceStart: sourceTime,
                    sourceEnd: clip.sourceEnd,
                    playbackRate: clip.playbackRate
                ),
            ]
        )
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

    /// Converts source-time Click Cues into project time and drops cues outside the edited timeline.
    public static func remapContentLayers(_ project: DemoProject) -> DemoProject {
        var result = project
        var projectCursor = 0.0
        var mappedClicks: [TimedPointerClick] = []

        for clip in result.clips {
            defer { projectCursor += clip.outputDuration }
            guard clip.kind == .video else { continue }
            for click in result.clicks where
                click.sourceTime >= clip.sourceStart
                    && click.sourceTime < clip.sourceEnd {
                var mapped = click
                let newTime = projectCursor
                    + (click.sourceTime - clip.sourceStart) / clip.playbackRate
                let offset = newTime - click.time
                mapped.time = newTime
                mapped.indicator.startTime += offset
                mapped.indicator.endTime += offset
                mapped.description.startTime += offset
                mapped.description.endTime += offset
                mapped.cueSubtitle.startTime += offset
                mapped.cueSubtitle.endTime += offset
                mappedClicks.append(mapped)
            }
        }
        let timelineDuration = result.timelineDuration
        result.clicks = mappedClicks.map {
            boundedClickWindows($0, timelineDuration: timelineDuration)
        }.sorted { $0.time < $1.time }
        let clickByID = Dictionary(
            uniqueKeysWithValues: result.clicks.map { ($0.id, $0) }
        )
        result.suggestions = result.suggestions.compactMap { suggestion in
            guard let click = clickByID[suggestion.clickID] else {
                return suggestion.state == .applied ? suggestion : nil
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
            return ClickEditSuggestion(
                id: existing[click.id]?.id ?? UUID(),
                clickID: click.id,
                splitTime: click.time,
                spotlight: SpotlightEffect(
                    id: existing[click.id]?.spotlight.id ?? UUID(),
                    startTime: start,
                    endTime: max(end, start + 0.01),
                    x: max(click.x - 0.12, 0),
                    y: max(click.y - 0.08, 0),
                    width: min(0.24, 1 - max(click.x - 0.12, 0)),
                    height: min(0.16, 1 - max(click.y - 0.08, 0))
                ),
                panZoom: PanZoomEffect(
                    id: existing[click.id]?.panZoom.id ?? UUID(),
                    startTime: start,
                    endTime: max(end, start + 0.01),
                    endX: click.x,
                    endY: click.y,
                    endScale: 1.5
                )
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
        if let clip = result.clips.first(where: {
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
        result.effects.append(.spotlight(suggestion.spotlight))
        result.effects.append(.panZoom(suggestion.panZoom))
        guard let remappedIndex = result.suggestions.firstIndex(
            where: { $0.id == suggestionID }
        ) else {
            throw ClickSuggestionError.suggestionNotFound
        }
        result.suggestions[remappedIndex].state = .applied
        return result
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
