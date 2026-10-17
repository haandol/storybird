import Foundation

/// One property inventory supplies the editor, MCP schema and input checking.
/// Persistence paths stay internal; clients use the explicit public field names.
public struct ProjectEditField: Codable, Sendable {
    public enum ValueType: String, Codable, Sendable { case number, string, boolean }
    public var type: ValueType
    public var minimum: Double?
    public var maximum: Double?
    public var exclusiveMinimum: Double?
    public var choices: [String]?
    public var pattern: String?
    public var description: String
    var path: [String]

    private enum CodingKeys: String, CodingKey {
        case type, minimum, maximum, exclusiveMinimum, choices, pattern, description
    }

    init(_ type: ValueType, _ path: String, minimum: Double? = nil, maximum: Double? = nil,
         exclusiveMinimum: Double? = nil, choices: [String]? = nil, pattern: String? = nil, description: String = "") {
        self.type = type
        self.path = path.isEmpty ? [] : path.split(separator: ".").map(String.init)
        self.minimum = minimum
        self.maximum = maximum
        self.exclusiveMinimum = exclusiveMinimum
        self.choices = choices
        self.pattern = pattern
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(ValueType.self, forKey: .type)
        minimum = try c.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum)
        exclusiveMinimum = try c.decodeIfPresent(Double.self, forKey: .exclusiveMinimum)
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        description = try c.decode(String.self, forKey: .description)
        path = []
    }

    func validate(_ value: ProjectEditValue, key: String) throws {
        let valid: Bool
        switch (type, value) {
        case let (.number, .number(number)):
            valid = number.isFinite && minimum.map { number >= $0 } != false
                && maximum.map { number <= $0 } != false && exclusiveMinimum.map { number > $0 } != false
        case let (.string, .string(string)):
            valid = choices?.contains(string) != false
                && pattern.map { string.range(of: $0, options: .regularExpression) != nil } != false
        case (.boolean, .boolean): valid = true
        default: valid = false
        }
        guard valid else {
            throw ProjectEditError(code: "invalid_value", property: key, allowedRange: allowedDescription,
                message: "Invalid \(key). No changes were saved.")
        }
    }

    var allowedDescription: String {
        if let choices { return choices.joined(separator: ", ") }
        if let pattern { return "string matching \(pattern)" }
        return [type.rawValue, minimum.map { ">= \($0)" }, maximum.map { "<= \($0)" },
                exclusiveMinimum.map { "> \($0)" }, description.isEmpty ? nil : description]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public enum ProjectEditFields {
    private static func number(_ path: String, min: Double? = 0, max: Double? = nil,
                               positive: Bool = false) -> ProjectEditField {
        ProjectEditField(.number, path, minimum: positive ? nil : min,
            maximum: max, exclusiveMinimum: positive ? 0 : nil)
    }
    private static func text(_ path: String, choices: [String]? = nil) -> ProjectEditField {
        ProjectEditField(.string, path, choices: choices,
            pattern: path.lowercased().hasSuffix("hex") ? "^#[0-9A-Fa-f]{6}$" : nil)
    }
    private static let timing = text("", choices: ["project", "scene"])

    public static var placement: [String: ProjectEditField] { [
        "fit_mode": text("placement.mode", choices: ["fit", "fill"]),
        "anchor_x": number("placement.anchorX", max: 1),
        "anchor_y": number("placement.anchorY", max: 1),
    ] }

    public static var style: [String: ProjectEditField] { [
        "foreground_hex": text("style.foregroundHex"), "background_hex": text("style.backgroundHex"),
        "background_opacity": number("style.backgroundOpacity", max: 1),
        "font_size": number("style.fontSize", min: 1),
    ] }

    public static func clip(_ kind: VideoClipKind, sourceDuration: Double? = nil) -> [String: ProjectEditField] {
        var fields = placement
        switch kind {
        case .video:
            fields["source_start"] = number("sourceStart", max: sourceDuration)
            fields["source_end"] = number("sourceEnd", max: sourceDuration, positive: true)
            fields["playback_rate"] = number("playbackRate", min: 0.25, max: 4)
        case .freeze:
            fields["source_time"] = number("", max: sourceDuration)
            fields["duration"] = number("freezeDuration", positive: true)
        case .image: fields["duration"] = number("freezeDuration", positive: true)
        }
        return fields
    }

    public static var subtitle: [String: ProjectEditField] {
        style.merging([
            "text": text("text"), "position": text("position", choices: SubtitlePosition.allCases.map(\.rawValue)),
            "start_time": number("startTime"), "end_time": number("endTime", positive: true),
            "timing_mode": timing,
        ]) { _, new in new }
    }

    public static var audio: [String: ProjectEditField] { [
        "name": text("name"), "start_time": number("startTime"), "source_start": number("sourceStart"),
        "duration": number("duration", positive: true), "volume": number("volume"),
        "muted": ProjectEditField(.boolean, "isMuted"),
        "fade_in": number("fadeIn"), "fade_out": number("fadeOut"), "timing_mode": timing,
    ] }

    public static var project: [String: ProjectEditField] { [
        "name": text("name"), "source_audio_volume": number("sourceAudioVolume"),
        "source_audio_muted": ProjectEditField(.boolean, "sourceAudioMuted"),
        "canvas_preset": text("canvas.preset", choices: ProjectCanvas.Preset.allCases.map(\.rawValue)),
        "canvas_background_hex": text("canvas.backgroundHex"),
    ] }

    public static var click: [String: ProjectEditField] {
        var fields: [String: ProjectEditField] = [
            "time": number("time"), "x": number("x", max: 1), "y": number("y", max: 1),
            "button": text("button", choices: PointerButton.allCases.map(\.rawValue)),
            "indicator_start_time": number("indicator.startTime"),
            "indicator_end_time": number("indicator.endTime", positive: true),
            "indicator_color_hex": text("indicator.colorHex"),
            "indicator_opacity": number("indicator.opacity", max: 1),
            "indicator_size": number("indicator.size", positive: true),
            "description": text("description.text"),
            "description_start_time": number("description.startTime"),
            "description_end_time": number("description.endTime", positive: true),
            "description_position": text("description.position", choices: ["automatic", "custom"]),
            "description_x": number("description.x", max: 1), "description_y": number("description.y", max: 1),
            "subtitle": text("cueSubtitle.text"),
            "subtitle_start_time": number("cueSubtitle.startTime"),
            "subtitle_end_time": number("cueSubtitle.endTime", positive: true),
            "subtitle_position": text("cueSubtitle.position", choices: SubtitlePosition.allCases.map(\.rawValue)),
        ]
        for (prefix, path) in [("description", "description"), ("subtitle", "cueSubtitle")] {
            for (name, var field) in style {
                field.path.insert(path, at: 0)
                fields["\(prefix)_\(name)"] = field
            }
        }
        return fields
    }

    public static func effect(_ effect: DemoEffect) -> [String: ProjectEditField] {
        var fields: [String: ProjectEditField] = [
            "start_time": number("startTime"), "end_time": number("endTime", positive: true),
        ]
        switch effect {
        case .spotlight:
            fields.merge(["x": number("x", max: 1), "y": number("y", max: 1),
                "width": number("width", max: 1, positive: true), "height": number("height", max: 1, positive: true),
                "dim_opacity": number("dimOpacity", max: 1)]) { _, new in new }
        case .panZoom:
            for prefix in ["start", "end"] {
                fields["\(prefix)_x"] = number("\(prefix)X", max: 1)
                fields["\(prefix)_y"] = number("\(prefix)Y", max: 1)
                fields["\(prefix)_scale"] = number("\(prefix)Scale", min: 1, max: 3)
            }
        case .title:
            fields.merge(style) { _, new in new }
            fields["title"] = text("title")
            fields["subtitle"] = text("subtitle")
        case .cta:
            fields.merge(style) { _, new in new }
            fields["title"] = text("title")
            fields["button_label"] = text("buttonLabel")
        }
        return fields
    }

    /// Patches only advertised scalar fields on a value snapshot. The final
    /// planner validates relationships, timing and ownership across all targets.
    static func patch<T: Codable>(_ original: T, values: [String: ProjectEditValue],
                                  fields: [String: ProjectEditField]) throws -> T {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for (key, value) in values {
            guard let field = fields[key] else {
                throw ProjectEditError(code: "unknown_property", property: key,
                    allowedRange: fields.keys.sorted().joined(separator: ", "), message: "Unknown editable property: \(key).")
            }
            try field.validate(value, key: key)
            if !field.path.isEmpty { set(value.foundationValue, path: field.path[...], in: &object) }
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.strictProjectEdits] = true
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func values<T: Encodable>(_ original: T, fields: [String: ProjectEditField]) throws -> [String: ProjectEditValue] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        var result: [String: ProjectEditValue] = [:]
        for (key, field) in fields where !field.path.isEmpty {
            var value: Any? = object
            for component in field.path { value = (value as? [String: Any])?[component] }
            switch field.type {
            case .number: if let number = value as? NSNumber { result[key] = .number(number.doubleValue) }
            case .string: if let string = value as? String { result[key] = .string(string) }
            case .boolean: if let boolean = value as? Bool { result[key] = .boolean(boolean) }
            }
        }
        return result
    }

    private static func set(_ value: Any, path: ArraySlice<String>, in object: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 { object[key] = value; return }
        var child = object[key] as? [String: Any] ?? [:]
        set(value, path: path.dropFirst(), in: &child)
        object[key] = child
    }
}
