import CoreFoundation
import Foundation
import StorybirdCore

enum AgentEditError: LocalizedError {
    case invalidField(String)
    case missingTarget(String)
    var errorDescription: String? {
        switch self {
        case let .invalidField(field): "Invalid edit field: \(field). No changes were saved."
        case let .missingTarget(target): "The \(target) no longer exists. Refresh the edit context."
        }
    }
}

struct AgentEditArguments {
    let values: [String: Any]
    func has(_ key: String) -> Bool { values[key] != nil }

    /// Rejects mistyped, nonfinite and out-of-range numbers before model initializers can clamp them.
    func number(_ key: String, default fallback: Double? = nil, range: ClosedRange<Double>? = nil) throws -> Double {
        guard let raw = values[key] else {
            if let fallback { return fallback }
            throw AgentEditError.invalidField(key)
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw AgentEditError.invalidField(key)
        }
        let value = number.doubleValue
        guard range?.contains(value) != false else { throw AgentEditError.invalidField(key) }
        return value
    }

    /// Reads exact strings; absent optional values preserve the existing property.
    func text(_ key: String, default fallback: String? = nil) throws -> String {
        if let value = values[key] as? String { return value }
        if values[key] == nil, let fallback { return fallback }
        throw AgentEditError.invalidField(key)
    }

    func id(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try text(key)) else { throw AgentEditError.invalidField(key) }
        return id
    }

    /// Rejects properties belonging to another effect type rather than silently ignoring them.
    func requireKnown(_ fields: Set<String>) throws {
        let envelope: Set<String> = ["project_id", "expected_revision", "click_id", "effect_id", "suggestion_id", "subtitle_id"]
        if let unknown = Set(values.keys).subtracting(fields.union(envelope)).sorted().first {
            throw AgentEditError.invalidField(unknown)
        }
    }
}

enum AgentProjectEditor {
    static let spotlightFields: Set<String> = ["start_time", "end_time", "x", "y", "width", "height", "dim_opacity"]
    static let zoomFields: Set<String> = ["start_time", "end_time", "start_x", "start_y", "start_scale", "end_x", "end_y", "end_scale"]
    static let styleFields: Set<String> = ["foreground_hex", "background_hex", "background_opacity", "font_size"]

    /// Applies one narrow domain edit to a value copy. Only the AppStore writer
    /// can validate and publish it, so failures never leave partially changed layers.
    static func apply(_ name: String, arguments: [String: Any], to project: DemoProject) throws -> DemoProject {
        let a = AgentEditArguments(values: arguments)
        var result = project
        switch name {
        case "storybird_create_click":
            result = try VideoTimelineEditor.addClickCue(
                to: project, at: a.number("time"), x: a.number("x"), y: a.number("y")
            )
            let index = result.clicks.firstIndex { click in !project.clicks.contains { $0.id == click.id } }!
            result.clicks[index] = try click(result.clicks[index], arguments: arguments, project: result)
        case "storybird_update_click":
            let id = try a.id("click_id")
            guard let index = result.clicks.firstIndex(where: { $0.id == id }) else { throw AgentEditError.missingTarget("click") }
            result.clicks[index] = try click(result.clicks[index], arguments: arguments, project: result)
            result.clicks.sort { $0.time < $1.time }
            try VideoProjectValidator.validate(result)
            if a.has("time") { result = VideoTimelineEditor.remapContentLayers(result) }
        case "storybird_delete_click":
            let id = try a.id("click_id")
            guard result.clicks.contains(where: { $0.id == id }) else { throw AgentEditError.missingTarget("click") }
            result.clicks.removeAll { $0.id == id }
            result.suggestions.removeAll { $0.clickID == id }
        case "storybird_delete_subtitle":
            let id = try a.id("subtitle_id")
            guard result.subtitles.contains(where: { $0.id == id }) else { throw AgentEditError.missingTarget("subtitle") }
            result.subtitles.removeAll { $0.id == id }
        case "storybird_create_spotlight":
            try a.requireKnown(spotlightFields)
            let effect = try spotlight(a)
            result.effects.append(VideoTimelineEditor.anchorContentEffect(.spotlight(effect), in: result, at: effect.startTime))
        case "storybird_create_pan_zoom":
            try a.requireKnown(zoomFields)
            let effect = try zoom(a)
            result.effects.append(VideoTimelineEditor.anchorContentEffect(.panZoom(effect), in: result, at: effect.startTime))
        case "storybird_insert_title":
            result = try DemoEffectEditor.insertTitle(
                in: result, after: a.has("after_clip_id") ? a.id("after_clip_id") : nil,
                duration: a.number("duration", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude),
                title: a.text("title")
            )
        case "storybird_insert_cta":
            result = try DemoEffectEditor.insertCTA(
                in: result, duration: a.number("duration", range: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude),
                title: a.text("title"), buttonLabel: a.text("button_label")
            )
        case "storybird_delete_effect":
            result = try DemoEffectEditor.delete(a.id("effect_id"), from: result)
        case "storybird_update_effect":
            let id = try a.id("effect_id")
            guard let index = result.effects.firstIndex(where: { $0.id == id }) else { throw AgentEditError.missingTarget("effect") }
            switch result.effects[index] {
            case let .spotlight(value):
                try a.requireKnown(spotlightFields)
                result.effects[index] = .spotlight(try spotlight(a, existing: value))
            case let .panZoom(value):
                try a.requireKnown(zoomFields)
                result.effects[index] = .panZoom(try zoom(a, existing: value))
            case var .title(value):
                try a.requireKnown(styleFields.union(["start_time", "end_time", "title", "subtitle"]))
                value.startTime = try a.number("start_time", default: value.startTime)
                value.endTime = try a.number("end_time", default: value.endTime)
                value.title = try a.text("title", default: value.title)
                value.subtitle = try a.text("subtitle", default: value.subtitle)
                value.style = try style(a, existing: value.style)
                result.effects[index] = .title(value)
            case var .cta(value):
                try a.requireKnown(styleFields.union(["start_time", "end_time", "title", "button_label"]))
                value.startTime = try a.number("start_time", default: value.startTime)
                value.endTime = try a.number("end_time", default: value.endTime)
                value.title = try a.text("title", default: value.title)
                value.buttonLabel = try a.text("button_label", default: value.buttonLabel)
                value.style = try style(a, existing: value.style)
                result.effects[index] = .cta(value)
            }
            if result.effects[index].isFullScreenCard {
                result = try DemoEffectEditor.replaceCard(result.effects[index], in: project)
            } else {
                try VideoProjectValidator.validate(result)
                if a.has("start_time") || a.has("end_time") {
                    _ = try SceneTiming.anchor(at: result.effects[index].startTime, in: result)
                }
                result = try VideoTimelineEditor.reanchorChangedContentEffectTimes(from: project, to: result)
            }
        case "storybird_apply_suggestion":
            result = try ClickSuggestionGenerator.apply(a.id("suggestion_id"), to: result)
        case "storybird_reject_suggestion":
            result = try ClickSuggestionGenerator.reject(a.id("suggestion_id"), in: result)
        case "storybird_update_suggestion":
            let id = try a.id("suggestion_id")
            guard let index = result.suggestions.firstIndex(where: { $0.id == id }) else { throw AgentEditError.missingTarget("suggestion") }
            guard result.suggestions[index].state == .pending else { throw ClickSuggestionError.suggestionNotPending }
            result.suggestions[index].splitTime = try a.number("split_time", default: result.suggestions[index].splitTime, range: 0...project.timelineDuration)
            if let value = arguments["spotlight"] {
                guard let fields = value as? [String: Any] else { throw AgentEditError.invalidField("spotlight") }
                let nested = AgentEditArguments(values: fields)
                try nested.requireKnown(spotlightFields)
                result.suggestions[index].spotlight = try spotlight(nested, existing: result.suggestions[index].spotlight)
            }
            if let value = arguments["pan_zoom"] {
                guard let fields = value as? [String: Any] else { throw AgentEditError.invalidField("pan_zoom") }
                let nested = AgentEditArguments(values: fields)
                try nested.requireKnown(zoomFields)
                result.suggestions[index].panZoom = try zoom(nested, existing: result.suggestions[index].panZoom)
            }
        default: throw AgentEditError.invalidField("command")
        }
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Edits every visible Cue component without requiring a full project JSON.
    private static func click(_ original: TimedPointerClick, arguments: [String: Any], project: DemoProject) throws -> TimedPointerClick {
        let a = AgentEditArguments(values: arguments)
        var result = original
        if a.has("time") {
            result.time = try a.number("time", range: 0...project.timelineDuration)
        }
        let numbers: [String: WritableKeyPath<TimedPointerClick, Double>] = [
            "x": \.x, "y": \.y,
            "indicator_start_time": \.indicator.startTime, "indicator_end_time": \.indicator.endTime,
            "indicator_size": \.indicator.size, "indicator_opacity": \.indicator.opacity,
            "description_start_time": \.description.startTime, "description_end_time": \.description.endTime,
            "description_x": \.description.x, "description_y": \.description.y,
            "description_background_opacity": \.description.style.backgroundOpacity,
            "description_font_size": \.description.style.fontSize,
            "subtitle_start_time": \.cueSubtitle.startTime, "subtitle_end_time": \.cueSubtitle.endTime,
            "subtitle_background_opacity": \.cueSubtitle.style.backgroundOpacity,
            "subtitle_font_size": \.cueSubtitle.style.fontSize,
            "background_opacity": \.description.style.backgroundOpacity,
        ]
        for (key, path) in numbers where a.has(key) {
            if key == "background_opacity" && a.has("description_background_opacity") { continue }
            let normalized = key.hasSuffix("opacity") || ["x", "y", "description_x", "description_y"].contains(key)
            let lower = key.hasSuffix("font_size") ? 1 : (key == "indicator_size" ? Double.leastNonzeroMagnitude : 0)
            result[keyPath: path] = try a.number(key, range: lower...(normalized ? 1 : Double.greatestFiniteMagnitude))
        }
        let strings: [String: WritableKeyPath<TimedPointerClick, String>] = [
            "indicator_color_hex": \.indicator.colorHex,
            "description_foreground_hex": \.description.style.foregroundHex,
            "description_background_hex": \.description.style.backgroundHex,
            "subtitle": \.cueSubtitle.text, "subtitle_foreground_hex": \.cueSubtitle.style.foregroundHex,
            "subtitle_background_hex": \.cueSubtitle.style.backgroundHex,
        ]
        for (key, path) in strings where a.has(key) { result[keyPath: path] = try a.text(key) }
        result.description.text = try a.text("description", default: a.text("caption", default: result.description.text))
        result.description.style.backgroundHex = try a.text("description_background_hex", default: a.text("background_hex", default: result.description.style.backgroundHex))
        if a.has("button") {
            guard let value = PointerButton(rawValue: try a.text("button")) else { throw AgentEditError.invalidField("button") }
            result.button = value
        }
        if a.has("description_position") {
            guard let value = ClickDescriptionPosition(rawValue: try a.text("description_position")) else { throw AgentEditError.invalidField("description_position") }
            result.description.position = value
        }
        if a.has("subtitle_position") {
            guard let value = SubtitlePosition(rawValue: try a.text("subtitle_position")) else { throw AgentEditError.invalidField("subtitle_position") }
            result.cueSubtitle.position = value
        }
        return a.has("time") ? try ClickCueEditor.reanchorTime(result, in: project) : result
    }

    /// Preserves unspecified text styling and rejects invalid opacity/font size.
    private static func style(_ a: AgentEditArguments, existing: TextOverlayStyle) throws -> TextOverlayStyle {
        TextOverlayStyle(
            backgroundHex: try a.text("background_hex", default: existing.backgroundHex),
            backgroundOpacity: try a.number("background_opacity", default: existing.backgroundOpacity, range: 0...1),
            foregroundHex: try a.text("foreground_hex", default: existing.foregroundHex),
            fontSize: try a.number("font_size", default: existing.fontSize, range: 1...Double.greatestFiniteMagnitude)
        )
    }

    /// Builds a bounded spotlight from only the supplied fields.
    private static func spotlight(_ a: AgentEditArguments, existing: SpotlightEffect? = nil) throws -> SpotlightEffect {
        SpotlightEffect(
            id: existing?.id ?? UUID(), startTime: try a.number("start_time", default: existing?.startTime),
            endTime: try a.number("end_time", default: existing?.endTime),
            x: try a.number("x", default: existing?.x, range: 0...1), y: try a.number("y", default: existing?.y, range: 0...1),
            width: try a.number("width", default: existing?.width, range: Double.leastNonzeroMagnitude...1),
            height: try a.number("height", default: existing?.height, range: Double.leastNonzeroMagnitude...1),
            dimOpacity: try a.number("dim_opacity", default: existing?.dimOpacity ?? 0.55, range: 0...1), sourceAnchor: existing?.sourceAnchor
        )
    }

    /// Builds a bounded camera move without altering unrequested properties.
    private static func zoom(_ a: AgentEditArguments, existing: PanZoomEffect? = nil) throws -> PanZoomEffect {
        PanZoomEffect(
            id: existing?.id ?? UUID(), startTime: try a.number("start_time", default: existing?.startTime),
            endTime: try a.number("end_time", default: existing?.endTime),
            startX: try a.number("start_x", default: existing?.startX ?? 0.5, range: 0...1),
            startY: try a.number("start_y", default: existing?.startY ?? 0.5, range: 0...1),
            startScale: try a.number("start_scale", default: existing?.startScale ?? 1, range: 1...3),
            endX: try a.number("end_x", default: existing?.endX, range: 0...1),
            endY: try a.number("end_y", default: existing?.endY, range: 0...1),
            endScale: try a.number("end_scale", default: existing?.endScale, range: 1...3), sourceAnchor: existing?.sourceAnchor
        )
    }
}
