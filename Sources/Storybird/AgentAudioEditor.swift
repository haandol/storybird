import CoreFoundation
import Foundation
import StorybirdCore

enum AgentAudioEditor {
    /// Exposes narrow audio edits through the shared deterministic editor.
    /// Unknown fields and mistyped values fail before any publication.
    static func apply(_ name: String, arguments: [String: Any], to project: DemoProject) throws -> DemoProject {
        let a = AgentEditArguments(values: arguments)
        var result = project
        switch name {
        case "storybird_place_audio_asset":
            try a.requireKnown(["asset_id", "start_time", "source_start", "duration", "timing_mode"])
            result = try AudioLayerEditor.place(
                assetID: a.id("asset_id"), in: project, startTime: a.number("start_time"),
                sourceStart: a.number("source_start", default: 0),
                duration: a.has("duration") ? a.number("duration") : nil,
                timingMode: timing(a, fallback: .project)
            )
        case "storybird_update_audio_layer":
            try a.requireKnown(["layer_id", "name", "start_time", "source_start", "duration", "volume", "muted", "fade_in", "fade_out", "timing_mode"])
            let id = try a.id("layer_id")
            guard var layer = project.narrations.first(where: { $0.id == id }) else { throw AgentEditError.missingTarget("audio layer") }
            layer.name = try a.text("name", default: layer.name)
            layer.startTime = try a.number("start_time", default: layer.startTime)
            layer.sourceStart = try a.number("source_start", default: layer.sourceStart)
            layer.duration = try a.number("duration", default: layer.duration)
            layer.volume = try a.number("volume", default: layer.volume)
            layer.isMuted = try boolean(a, "muted", fallback: layer.isMuted)
            layer.fadeIn = try a.number("fade_in", default: layer.fadeIn)
            layer.fadeOut = try a.number("fade_out", default: layer.fadeOut)
            result = try AudioLayerEditor.replace(layer, in: project, timingMode: a.has("timing_mode") ? timing(a, fallback: .project) : nil)
        case "storybird_split_audio_layer":
            try a.requireKnown(["layer_id", "time"])
            result = try AudioLayerEditor.split(layerID: a.id("layer_id"), in: project, at: a.number("time"))
        case "storybird_duplicate_audio_layer":
            try a.requireKnown(["layer_id", "start_time"])
            result = try AudioLayerEditor.duplicate(layerID: a.id("layer_id"), in: project, startTime: a.has("start_time") ? a.number("start_time") : nil)
        case "storybird_delete_audio_layer":
            try a.requireKnown(["layer_id"])
            let id = try a.id("layer_id")
            guard result.narrations.contains(where: { $0.id == id }) else { throw AgentEditError.missingTarget("audio layer") }
            result.narrations.removeAll { $0.id == id }
        case "storybird_set_source_audio":
            try a.requireKnown(["volume", "muted"])
            result.sourceAudioVolume = try a.number("volume", default: project.sourceAudioVolume)
            result.sourceAudioMuted = try boolean(a, "muted", fallback: project.sourceAudioMuted)
        default: throw AgentEditError.invalidField("command")
        }
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Distinguishes actual JSON booleans from numbers before changing mute state.
    private static func boolean(_ a: AgentEditArguments, _ key: String, fallback: Bool) throws -> Bool {
        guard a.has(key) else { return fallback }
        guard let value = a.values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw AgentEditError.invalidField(key)
        }
        return value.boolValue
    }

    /// Preserves the fixed-time default of existing MCP calls.
    private static func timing(_ a: AgentEditArguments, fallback: LayerTimingMode) throws -> LayerTimingMode {
        guard a.has("timing_mode") else { return fallback }
        guard let mode = LayerTimingMode(rawValue: try a.text("timing_mode")) else { throw AgentEditError.invalidField("timing_mode") }
        return mode
    }
}
