import Foundation

/// Builds a complete value draft without touching storage, assets or jobs.
/// Structural edits run first, linked timing is derived once, then explicit
/// layer changes are applied. Only the complete result is globally validated.
public enum ProjectEditPlanner {
    /// Moves a selected clip group to an insertion index after its removal,
    /// preserving relative order and emitting one explicit move per selected ID.
    public static func moveClips(_ ids: Set<UUID>, to destination: Int, in project: DemoProject) throws -> [ProjectEdit] {
        let selected = project.clips.enumerated().filter { ids.contains($0.element.id) }
        guard !ids.isEmpty, selected.count == ids.count else { throw failure("missing_target", "Choose existing clip IDs.") }
        guard (0...(project.clips.count - ids.count)).contains(destination) else {
            throw ProjectEditError(code: "invalid_value", property: "destination_index",
                allowedRange: "0...\(project.clips.count - ids.count)", message: "Invalid group insertion position.")
        }
        let edits = selected.enumerated().map { index, value in
            ProjectEdit(target: .clip, id: value.element.id, action: .move,
                values: ["destination_index": .number(Double(destination + index))])
        }
        return destination > (selected.first?.offset ?? 0) ? edits.reversed() : edits
    }

    public static func plan(_ edits: [ProjectEdit], in project: DemoProject) throws -> ProjectEditPlan {
        guard !edits.isEmpty else { throw failure("empty_edits", "Specify at least one edit.") }
        let original = snapshots(project)
        var requested = Set<ProjectEditReference>()
        for (index, edit) in edits.enumerated() {
            if !edit.relatedIDs.isEmpty, edit.action != .merge || edit.target != .subtitle {
                throw ProjectEditError(code: "unknown_property", operationIndex: index, targetID: edit.id,
                    property: "related_ids", message: "Related IDs are only supported for independent caption merge.")
            }
            for id in [edit.id] + edit.relatedIDs {
                let ref = ProjectEditReference(target: edit.target, id: id)
                let property = id == edit.id ? "id" : "related_ids"
                guard original[ref] != nil else {
                    throw ProjectEditError(code: "missing_target", operationIndex: index, targetID: id,
                        property: property, allowedRange: "existing stable target IDs from get_edit_context",
                        message: "The explicit target does not exist. Refresh the edit context.")
                }
                guard requested.insert(ref).inserted else {
                    throw ProjectEditError(code: "duplicate_target", operationIndex: index, targetID: id,
                        property: property, allowedRange: "one explicit edit per target",
                        message: "Specify each target once in a batch.")
                }
            }
        }
        var result = project
        var created: [ProjectEditCreation] = []
        let structural = edits.indices.filter { isStructural(edits[$0], in: project) }
        // Keep the ordered array for execution; membership need not rescan it
        // for every non-structural edit in the second phase.
        let structuralIndices = Set(structural)
        for index in structural {
            let before = Set(references(in: result))
            result = try contextual(index, edits[index]) { try apply(edits[index], to: result) }
            let inserted = references(in: result).filter { !before.contains($0) }
            if !inserted.isEmpty {
                created.append(ProjectEditCreation(operationIndex: index, sourceID: edits[index].id,
                    created: ordered(inserted)))
            }
        }
        let cardTimes: (DemoProject) -> [String] = { value in
            value.effects.filter(\.isFullScreenCard).map { "\($0.id):\($0.startTime):\($0.endTime)" }
        }
        if result.clips != project.clips || cardTimes(result) != cardTimes(project) {
            result = VideoTimelineEditor.remapContentLayers(result)
        }
        let derived = result
        for index in edits.indices where !structuralIndices.contains(index) {
            let edit = edits[index]
            let before = Set(references(in: result))
            result = try contextual(index, edit) {
                let ref = ProjectEditReference(target: edit.target, id: edit.id)
                if edit.action == .delete, timing(of: ref, in: derived) == nil {
                    try requireOnly(edit, [])
                    return result
                }
                try rejectConflictingTiming(edit, original: project, derived: derived)
                return try apply(edit, to: result)
            }
            let inserted = references(in: result).filter { !before.contains($0) }
            if !inserted.isEmpty {
                created.append(ProjectEditCreation(operationIndex: index, sourceID: edit.id, created: ordered(inserted)))
            }
        }
        result.clicks.sort { $0.time < $1.time }
        do { try VideoProjectValidator.validate(result) }
        catch { throw validationFailure(error, project: result, edits: edits) }
        let final = snapshots(result)
        let changed = Set(original.keys).union(final.keys).filter { original[$0] != final[$0] }
        let direct = changed.filter { requested.contains($0) }
        return ProjectEditPlan(project: result, direct: ordered(direct),
            derived: ordered(changed.filter { !requested.contains($0) }), created: created)
    }

    public static func references(in project: DemoProject) -> [ProjectEditReference] {
        project.clips.map { ProjectEditReference(target: .clip, id: $0.id) }
            + project.clicks.map { ProjectEditReference(target: .click, id: $0.id) }
            + project.subtitles.map { ProjectEditReference(target: .subtitle, id: $0.id) }
            + project.narrations.map { ProjectEditReference(target: .audio, id: $0.id) }
            + project.effects.map { ProjectEditReference(target: .effect, id: $0.id) }
            + [ProjectEditReference(target: .project, id: project.id)]
    }

    /// Advertises only properties meaningful for this exact target and source.
    public static func fields(for target: ProjectEditTarget, id: UUID, in project: DemoProject) throws -> [String: ProjectEditField] {
        switch target {
        case .clip:
            guard let clip = project.clips.first(where: { $0.id == id }) else { throw missing(id) }
            return ProjectEditFields.clip(clip.kind, sourceDuration: project.mediaAsset(for: clip)?.duration)
        case .click: return ProjectEditFields.click
        case .subtitle: return ProjectEditFields.subtitle
        case .audio: return ProjectEditFields.audio
        case .project: return ProjectEditFields.project
        case .effect:
            guard let effect = project.effects.first(where: { $0.id == id }) else { throw missing(id) }
            return ProjectEditFields.effect(effect)
        }
    }

    /// Reads values through the same public property names used by edits. This
    /// lets UI and agents detect mixed selections without guessing JSON paths.
    public static func values(for reference: ProjectEditReference, in project: DemoProject) throws -> [String: ProjectEditValue] {
        let fields = try fields(for: reference.target, id: reference.id, in: project)
        var result: [String: ProjectEditValue]
        switch reference.target {
        case .clip:
            guard let clip = project.clips.first(where: { $0.id == reference.id }) else { throw missing(reference.id) }
            result = try ProjectEditFields.values(clip, fields: fields)
            if clip.kind == .freeze { result["source_time"] = .number(clip.sourceStart) }
        case .subtitle:
            guard let value = project.subtitles.first(where: { $0.id == reference.id }) else { throw missing(reference.id) }
            result = try ProjectEditFields.values(value, fields: fields)
            result["timing_mode"] = .string(value.sceneAnchor == nil ? "project" : "scene")
        case .audio:
            guard let value = project.narrations.first(where: { $0.id == reference.id }) else { throw missing(reference.id) }
            result = try ProjectEditFields.values(value, fields: fields)
            result["timing_mode"] = .string(value.sceneAnchor == nil ? "project" : "scene")
        case .click:
            guard let value = project.clicks.first(where: { $0.id == reference.id }) else { throw missing(reference.id) }
            result = try ProjectEditFields.values(value, fields: fields)
        case .project: result = try ProjectEditFields.values(project, fields: fields)
        case .effect:
            guard let value = project.effects.first(where: { $0.id == reference.id }) else { throw missing(reference.id) }
            switch value {
            case let .spotlight(value): result = try ProjectEditFields.values(value, fields: fields)
            case let .panZoom(value): result = try ProjectEditFields.values(value, fields: fields)
            case let .title(value): result = try ProjectEditFields.values(value, fields: fields)
            case let .cta(value): result = try ProjectEditFields.values(value, fields: fields)
            case let .mask(value):
                result = try ProjectEditFields.values(value, fields: fields)
                result["order_index"] = .number(Double(project.effects.filter(\.isMask).firstIndex { $0.id == value.id } ?? 0))
            }
        }
        return result
    }

    private static func isStructural(_ edit: ProjectEdit, in project: DemoProject) -> Bool {
        if edit.target == .clip {
            return edit.action != .update || !Set(edit.values.keys)
                .isDisjoint(with: ["source_start", "source_end", "source_time", "duration", "playback_rate"])
        }
        return edit.target == .effect && project.effects.contains { $0.id == edit.id && $0.isFullScreenCard }
            && (edit.action != .update || edit.values["start_time"] != nil || edit.values["end_time"] != nil)
    }

    private static func apply(_ edit: ProjectEdit, to project: DemoProject) throws -> DemoProject {
        var result = project
        switch edit.action {
        case .update:
            guard !edit.values.isEmpty else { throw failure("empty_values", "Specify a property to update.") }
            let fields = try fields(for: edit.target, id: edit.id, in: project)
            switch edit.target {
            case .clip:
                guard let index = result.clips.firstIndex(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                result.clips[index] = try ProjectEditFields.patch(result.clips[index], values: edit.values, fields: fields)
                if let time = edit.values["source_time"]?.number {
                    result.clips[index].sourceStart = time
                    result.clips[index].sourceEnd = time
                }
            case .subtitle:
                guard let index = result.subtitles.firstIndex(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                let old = result.subtitles[index]
                var next = try ProjectEditFields.patch(old, values: edit.values, fields: fields)
                if edit.values["timing_mode"] != nil || old.startTime != next.startTime {
                    next.sceneAnchor = try sceneAnchor(edit, old: old.sceneAnchor, time: next.startTime, project: result)
                }
                result.subtitles[index] = next
            case .audio:
                guard let old = result.narrations.first(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                let next = try ProjectEditFields.patch(old, values: edit.values, fields: fields)
                result = try AudioLayerEditor.replace(next, in: result,
                    timingMode: edit.values["timing_mode"]?.string.flatMap(LayerTimingMode.init(rawValue:)), validateResult: false)
            case .project:
                guard edit.id == result.id else { throw missing(edit.id) }
                result = try ProjectEditFields.patch(result, values: edit.values, fields: fields)
            case .click:
                guard let index = result.clicks.firstIndex(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                let old = result.clicks[index]
                var next = try ProjectEditFields.patch(old, values: edit.values, fields: fields)
                if next.time != old.time {
                    let delta = next.time - old.time
                    shiftCueWindows(&next, by: delta, except: Set(edit.values.keys))
                    try anchorClick(&next, in: result)
                }
                result.clicks[index] = next
                shiftSuggestions(for: next.id, by: next.time - old.time, in: &result)
            case .effect:
                guard let index = result.effects.firstIndex(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                let old = result.effects[index]
                if old.isMask {
                    result = try MaskEditor.update(edit.id, in: result, values: edit.values, validateResult: false)
                    break
                }
                let next = try patchEffect(old, values: edit.values)
                if old.isFullScreenCard {
                    result = try DemoEffectEditor.replaceCard(next, in: result, validateResult: false)
                } else {
                    result.effects[index] = next
                    if old.startTime != next.startTime || old.endTime != next.endTime {
                        result = try VideoTimelineEditor.reanchorChangedContentEffectTimes(from: project, to: result)
                    }
                }
            }
        case .delete:
            try requireOnly(edit, [])
            switch edit.target {
            case .clip: result = try VideoTimelineEditor.delete(project: result, clipID: edit.id, remapLayers: false)
            case .subtitle: result.subtitles.removeAll { $0.id == edit.id }
            case .audio: result.narrations.removeAll { $0.id == edit.id }
            case .click:
                result.clicks.removeAll { $0.id == edit.id }
                result.suggestions.removeAll { $0.clickID == edit.id }
            case .effect: result = try DemoEffectEditor.delete(edit.id, from: result)
            case .project: throw unsupported(edit)
            }
        case .move:
            if edit.target == .clip {
                try requireOnly(edit, ["destination_index"])
                result = try VideoTimelineEditor.move(project: result, clipID: edit.id,
                    destination: integer("destination_index", edit), remapLayers: false)
            } else {
                try requireOnly(edit, ["delta"])
                result = try TimelineLayerEditor.move(layerTarget(edit), by: number("delta", edit),
                    in: result, validateResult: false)
            }
        case .duplicate:
            if edit.target == .clip {
                try requireOnly(edit, ["destination_index"])
                result = try VideoTimelineEditor.duplicate(project: result, clipID: edit.id,
                    destination: integer("destination_index", edit), remapLayers: false)
            } else {
                try requireOnly(edit, ["start_time"])
                result = try duplicateLayer(edit, at: number("start_time", edit), in: result)
            }
        case .split:
            switch edit.target {
            case .clip:
                guard let clip = result.clips.first(where: { $0.id == edit.id }) else { throw missing(edit.id) }
                if clip.kind == .video {
                    try requireOnly(edit, ["source_time"])
                    result = try VideoTimelineEditor.split(project: result, clipID: edit.id,
                        sourceTime: number("source_time", edit), remapLayers: false)
                } else {
                    try requireOnly(edit, ["clip_offset"])
                    result = try VideoTimelineEditor.splitHeld(project: result, clipID: edit.id,
                        clipOffset: number("clip_offset", edit), remapLayers: false)
                }
            case .audio:
                try requireOnly(edit, ["time"])
                result = try AudioLayerEditor.split(layerID: edit.id, in: result, at: number("time", edit), validateResult: false)
            case .subtitle:
                try requireOnly(edit, ["time", "text_offset"])
                result = try SubtitleEditing.split(edit.id, in: result, at: number("time", edit), textOffset: integer("text_offset", edit))
            default: throw unsupported(edit)
            }
        case .merge:
            guard edit.target == .subtitle else { throw unsupported(edit) }
            try requireOnly(edit, Set(ProjectEditFields.subtitle.keys).subtracting(["start_time", "end_time"]))
            guard let text = edit.values["text"]?.string else {
                throw ProjectEditError(code: "invalid_value", property: "text", message: "Supply the exact combined caption text.")
            }
            result = try SubtitleEditing.merge(edit.id, relatedIDs: edit.relatedIDs, text: text, in: result)
            result = try apply(ProjectEdit(target: .subtitle, id: edit.id, action: .update, values: edit.values), to: result)
        }
        return result
    }

    private static func duplicateLayer(_ edit: ProjectEdit, at start: Double, in project: DemoProject) throws -> DemoProject {
        var result = project
        switch edit.target {
        case .audio:
            return try AudioLayerEditor.duplicate(layerID: edit.id, in: project, startTime: start, validateResult: false)
        case .subtitle:
            guard var copy = result.subtitles.first(where: { $0.id == edit.id }) else { throw missing(edit.id) }
            copy.id = UUID()
            copy.endTime = start + copy.endTime - copy.startTime
            copy.startTime = start
            if copy.sceneAnchor != nil { copy.sceneAnchor = try SceneTiming.anchor(at: start, in: project) }
            result.subtitles.append(copy)
        case .click:
            guard var copy = result.clicks.first(where: { $0.id == edit.id }) else { throw missing(edit.id) }
            copy.id = UUID()
            let delta = start - copy.time
            copy.time = start
            shiftCueWindows(&copy, by: delta)
            try anchorClick(&copy, in: project)
            result.clicks.append(copy)
            // The new Cue gets its own independent pending suggestion bundle.
            if let suggestion = ClickSuggestionGenerator.generate(for: result).first(where: { $0.clickID == copy.id }) {
                result.suggestions.append(suggestion)
            }
        case .effect:
            guard let original = result.effects.first(where: { $0.id == edit.id }) else { throw missing(edit.id) }
            guard !original.isCTA else { throw DemoEffectEditError.ctaAlreadyExists }
            if case .title = original {
                return try DemoEffectEditor.duplicateTitle(edit.id, in: project, at: start, validateResult: false)
            }
            let duration = original.endTime - original.startTime
            let moved = try patchEffect(original, values: ["start_time": .number(start), "end_time": .number(start + duration)])
            let copy: DemoEffect
            switch moved {
            case var .spotlight(value): value.id = UUID(); copy = .spotlight(value)
            case var .panZoom(value): value.id = UUID(); copy = .panZoom(value)
            case var .title(value): value.id = UUID(); copy = .title(value)
            case .cta: throw DemoEffectEditError.ctaAlreadyExists
            case var .mask(value):
                value.id = UUID()
                if value.timingMode == .scene { value.sceneAnchor = try SceneTiming.anchor(at: start, in: project) }
                copy = .mask(value)
            }
            let anchored = VideoTimelineEditor.anchorContentEffect(copy, in: project, at: start)
            result.effects.append(anchored)
        case .clip, .project: throw unsupported(edit)
        }
        return result
    }

    private static func patchEffect(_ effect: DemoEffect, values: [String: ProjectEditValue]) throws -> DemoEffect {
        let fields = ProjectEditFields.effect(effect)
        switch effect {
        case let .spotlight(value): return .spotlight(try ProjectEditFields.patch(value, values: values, fields: fields))
        case let .panZoom(value): return .panZoom(try ProjectEditFields.patch(value, values: values, fields: fields))
        case let .title(value): return .title(try ProjectEditFields.patch(value, values: values, fields: fields))
        case let .cta(value): return .cta(try ProjectEditFields.patch(value, values: values, fields: fields))
        case let .mask(value): return .mask(try ProjectEditFields.patch(value, values: values, fields: fields))
        }
    }

    private static func sceneAnchor(_ edit: ProjectEdit, old: LayerSceneAnchor?, time: Double,
                                    project: DemoProject) throws -> LayerSceneAnchor? {
        let mode = edit.values["timing_mode"]?.string ?? (old == nil ? "project" : "scene")
        return mode == "scene" ? try SceneTiming.anchor(at: time, in: project) : nil
    }

    private static func anchorClick(_ click: inout TimedPointerClick, in project: DemoProject) throws {
        guard let point = VideoTimelineSchedule(project: project).sourceLocation(at: click.time) else {
            throw VideoTimelineEditError.invalidClickPlacement
        }
        click.sourceTime = point.sourceTime
        click.sourceAnchor = ClickSourceAnchor(clipID: point.clipID, clipKind: point.clipKind, clipOffset: point.clipOffset)
    }

    private static func shiftCueWindows(_ click: inout TimedPointerClick, by delta: Double, except keys: Set<String> = []) {
        if !keys.contains("indicator_start_time") { click.indicator.startTime += delta }
        if !keys.contains("indicator_end_time") { click.indicator.endTime += delta }
        if !keys.contains("description_start_time") { click.description.startTime += delta }
        if !keys.contains("description_end_time") { click.description.endTime += delta }
        if !keys.contains("subtitle_start_time") { click.cueSubtitle.startTime += delta }
        if !keys.contains("subtitle_end_time") { click.cueSubtitle.endTime += delta }
    }

    private static func shiftSuggestions(for clickID: UUID, by delta: Double, in project: inout DemoProject) {
        for index in project.suggestions.indices where project.suggestions[index].clickID == clickID
            && project.suggestions[index].state == .pending {
            project.suggestions[index].splitTime += delta
            project.suggestions[index].spotlight.startTime += delta
            project.suggestions[index].spotlight.endTime += delta
            project.suggestions[index].panZoom.startTime += delta
            project.suggestions[index].panZoom.endTime += delta
        }
    }

    private static func timing(of reference: ProjectEditReference, in project: DemoProject) -> [String: Double]? {
        switch reference.target {
        case .subtitle:
            return project.subtitles.first { $0.id == reference.id }.map { ["start_time": $0.startTime, "end_time": $0.endTime] }
        case .audio:
            return project.narrations.first { $0.id == reference.id }.map { ["start_time": $0.startTime] }
        case .effect:
            return project.effects.first { $0.id == reference.id }.map { ["start_time": $0.startTime, "end_time": $0.endTime] }
        case .click:
            return project.clicks.first { $0.id == reference.id }.map {
                ["time": $0.time, "indicator_start_time": $0.indicator.startTime, "indicator_end_time": $0.indicator.endTime,
                 "description_start_time": $0.description.startTime, "description_end_time": $0.description.endTime,
                 "subtitle_start_time": $0.cueSubtitle.startTime, "subtitle_end_time": $0.cueSubtitle.endTime]
            }
        case .clip, .project: return [:]
        }
    }

    private static func rejectConflictingTiming(_ edit: ProjectEdit, original: DemoProject, derived: DemoProject) throws {
        let reference = ProjectEditReference(target: edit.target, id: edit.id)
        guard let before = timing(of: reference, in: original), let after = timing(of: reference, in: derived) else {
            throw failure("derived_target_removed", "A clip edit removes this explicit layer target.")
        }
        guard before != after || sceneOwner(of: reference, in: original) != sceneOwner(of: reference, in: derived) else { return }
        if edit.action == .move, try number("delta", edit) != 0 {
            throw failure("conflicting_timing", "This layer already moves with its scene. Omit the conflicting direct move.")
        }
        if edit.action == .update {
            for (property, time) in after {
                if let requested = edit.values[property]?.number, abs(requested - time) > 0.000_001 {
                    throw ProjectEditError(code: "conflicting_timing", property: property,
                        allowedRange: "Derived scene time: \(time) seconds",
                        message: "Direct timing conflicts with this layer's scene edit.")
                }
            }
        }
    }

    /// Returns the exact scene owner, or nil for fixed-time content.
    public static func sceneOwner(of reference: ProjectEditReference, in project: DemoProject) -> UUID? {
        switch reference.target {
        case .subtitle: project.subtitles.first { $0.id == reference.id }?.sceneAnchor?.clipID
        case .audio: project.narrations.first { $0.id == reference.id }?.sceneAnchor?.clipID
        case .click: project.clicks.first { $0.id == reference.id }?.sourceAnchor?.clipID
        case .effect:
            switch project.effects.first(where: { $0.id == reference.id }) {
            case let .spotlight(value): value.sourceAnchor?.clipID
            case let .panZoom(value): value.sourceAnchor?.clipID
            case let .mask(value): value.sceneAnchor?.clipID
            default: nil
            }
        case .clip, .project: nil
        }
    }

    private static func layerTarget(_ edit: ProjectEdit) throws -> TimelineLayerTarget {
        switch edit.target {
        case .click: .click(edit.id)
        case .subtitle: .subtitle(edit.id)
        case .audio: .narration(edit.id)
        case .effect: .effect(edit.id)
        case .clip, .project: throw unsupported(edit)
        }
    }

    private static func number(_ key: String, _ edit: ProjectEdit) throws -> Double {
        guard let value = edit.values[key]?.number, value.isFinite else {
            throw ProjectEditError(code: "invalid_value", property: key, allowedRange: "finite number",
                message: "Specify \(key) as a finite number.")
        }
        return value
    }
    private static func integer(_ key: String, _ edit: ProjectEdit) throws -> Int {
        guard let value = Int(exactly: try number(key, edit)) else {
            throw ProjectEditError(code: "invalid_value", property: key, allowedRange: "integer", message: "Specify an integer insertion index.")
        }
        return value
    }
    private static func requireOnly(_ edit: ProjectEdit, _ keys: Set<String>) throws {
        if let key = Set(edit.values.keys).subtracting(keys).sorted().first {
            throw ProjectEditError(code: "unknown_property", property: key,
                allowedRange: keys.sorted().joined(separator: ", "), message: "Unknown property for \(edit.action.rawValue): \(key).")
        }
    }
    private static func contextual(_ index: Int, _ edit: ProjectEdit, body: () throws -> DemoProject) throws -> DemoProject {
        do { return try body() }
        catch var error as ProjectEditError {
            error.operationIndex = index
            error.targetID = error.targetID ?? edit.id
            throw error
        } catch {
            throw ProjectEditError(code: "invalid_edit", operationIndex: index, targetID: edit.id,
                property: "values", message: error.localizedDescription)
        }
    }
    private static func missing(_ id: UUID) -> ProjectEditError {
        ProjectEditError(code: "missing_target", targetID: id, message: "The target no longer exists.")
    }
    private static func unsupported(_ edit: ProjectEdit) -> ProjectEditError {
        ProjectEditError(code: "unsupported_action", targetID: edit.id, property: "action",
            message: "\(edit.action.rawValue) is not supported for \(edit.target.rawValue).")
    }
    private static func failure(_ code: String, _ message: String) -> ProjectEditError {
        ProjectEditError(code: code, message: message)
    }
    private static func validationFailure(_ error: Error, project: DemoProject, edits: [ProjectEdit]) -> ProjectEditError {
        if case let .effectConflict(id, other, start, end) = error as? VideoProjectValidationError {
            let operation = edits.firstIndex { $0.id == id || $0.id == other }
            return ProjectEditError(code: "effect_conflict", operationIndex: operation,
                targetID: operation.map { edits[$0].id } ?? id, property: "start_time/end_time",
                allowedRange: "Avoid overlapping \(start)...\(end) seconds", message: error.localizedDescription)
        }
        let id: UUID?
        switch error as? VideoProjectValidationError {
        case let .invalidClip(value), let .invalidClick(value), let .invalidSubtitle(value),
             let .invalidEffect(value), let .invalidSuggestion(value), let .invalidNarration(value, _),
             let .duplicateLayerID(value), let .invalidMediaAsset(value): id = value
        default: id = project.id
        }
        return ProjectEditError(code: "invalid_timeline", operationIndex: edits.firstIndex { $0.id == id },
            targetID: id, property: "values", allowedRange: "Project times 0...\(project.timelineDuration) seconds; owned source ranges and compatible layers",
            message: error.localizedDescription)
    }

    private struct ClipState: Encodable { var clip: VideoClip; var index: Int; var start: Double; var end: Double }
    private struct Header: Encodable { var name: String; var canvas: ProjectCanvas; var volume: Double; var muted: Bool }
    private static func snapshots(_ project: DemoProject) -> [ProjectEditReference: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var result: [ProjectEditReference: Data] = [:]
        func add<T: Encodable>(_ value: T, kind: ProjectEditTarget, id: UUID) {
            result[ProjectEditReference(target: kind, id: id)] = try? encoder.encode(value)
        }
        for (index, item) in VideoTimelineSchedule(project: project).items.enumerated() {
            if case let .clip(clip) = item {
                add(ClipState(clip: clip.clip, index: index, start: clip.projectStart, end: clip.projectEnd), kind: .clip, id: clip.clip.id)
            }
        }
        for value in project.clicks { add(value, kind: .click, id: value.id) }
        for value in project.subtitles { add(value, kind: .subtitle, id: value.id) }
        for value in project.narrations { add(value, kind: .audio, id: value.id) }
        for value in project.effects { add(value, kind: .effect, id: value.id) }
        add(Header(name: project.name, canvas: project.canvas, volume: project.sourceAudioVolume,
            muted: project.sourceAudioMuted), kind: .project, id: project.id)
        return result
    }
    private static func ordered<S: Sequence>(_ references: S) -> [ProjectEditReference] where S.Element == ProjectEditReference {
        references.sorted { ($0.target.rawValue, $0.id.uuidString) < ($1.target.rawValue, $1.id.uuidString) }
    }
}
