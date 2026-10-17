import Foundation

/// Scalar edit inputs keep the wire and native editor independent of persisted
/// JSON paths. Unknown keys and compound values cannot silently alter a model.
public enum ProjectEditValue: Codable, Hashable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a finite number, string or Boolean.") }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .number(number): try value.encode(number)
        case let .string(string): try value.encode(string)
        case let .boolean(boolean): try value.encode(boolean)
        }
    }

    var number: Double? { if case let .number(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var foundationValue: Any {
        switch self {
        case let .number(value): value
        case let .string(value): value
        case let .boolean(value): value
        }
    }
}

public enum ProjectEditTarget: String, Codable, CaseIterable, Sendable {
    case clip, click, subtitle, audio, effect, project
}

public enum ProjectEditAction: String, Codable, CaseIterable, Sendable {
    case update, move, duplicate, delete, split, merge
}

public struct ProjectEdit: Codable, Hashable, Sendable {
    public var target: ProjectEditTarget
    public var id: UUID
    public var action: ProjectEditAction
    public var values: [String: ProjectEditValue]
    public var relatedIDs: [UUID]

    public init(target: ProjectEditTarget, id: UUID, action: ProjectEditAction,
                values: [String: ProjectEditValue] = [:], relatedIDs: [UUID] = []) {
        self.target = target
        self.id = id
        self.action = action
        self.values = values
        self.relatedIDs = relatedIDs
    }

    private enum CodingKeys: String, CodingKey { case target, id, action, values; case relatedIDs = "related_ids" }

    /// Rejects unknown envelope keys too; accepting them would make a reviewed
    /// request mean something different from what its caller intended.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: EditCodingKey.self)
        let known: Set<String> = ["target", "id", "action", "values", "related_ids"]
        if let unknown = raw.allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw ProjectEditError(code: "unknown_property", property: unknown.stringValue,
                message: "Unknown edit property. No changes were saved.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(ProjectEditTarget.self, forKey: .target)
        id = try values.decode(UUID.self, forKey: .id)
        action = try values.decode(ProjectEditAction.self, forKey: .action)
        if values.contains(.relatedIDs), action != .merge {
            throw ProjectEditError(code: "unknown_property", property: "related_ids", message: "Related IDs are only valid for merge.")
        }
        self.values = try values.decodeIfPresent([String: ProjectEditValue].self, forKey: .values) ?? [:]
        relatedIDs = try values.decodeIfPresent([UUID].self, forKey: .relatedIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encode(values, forKey: .values)
        if action == .merge || !relatedIDs.isEmpty { try container.encode(relatedIDs, forKey: .relatedIDs) }
    }
}

private struct EditCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// The app adds the current revision to these structured failures. A rejected
/// draft carries its exact target/property instead of guessing a replacement.
public struct ProjectEditError: Error, LocalizedError, Codable, Equatable, Sendable {
    public var code: String
    public var operationIndex: Int?
    public var targetID: UUID?
    public var property: String?
    public var allowedRange: String?
    public var message: String
    public var errorDescription: String? { message }
    private enum CodingKeys: String, CodingKey {
        case code, message, property
        case operationIndex = "operation_index"
        case targetID = "target_id"
        case allowedRange = "allowed_range"
    }

    public init(code: String, operationIndex: Int? = nil, targetID: UUID? = nil,
                property: String? = nil, allowedRange: String? = nil, message: String) {
        self.code = code
        self.operationIndex = operationIndex
        self.targetID = targetID
        self.property = property
        self.allowedRange = allowedRange
        self.message = message
    }
}

public struct ProjectEditReference: Codable, Hashable, Sendable {
    public var target: ProjectEditTarget
    public var id: UUID
    public init(target: ProjectEditTarget, id: UUID) { self.target = target; self.id = id }
}

public struct ProjectEditCreation: Codable, Hashable, Sendable {
    public var operationIndex: Int
    public var sourceID: UUID
    public var created: [ProjectEditReference]
    private enum CodingKeys: String, CodingKey {
        case operationIndex = "operation_index"
        case sourceID = "source_id"
        case created
    }
}

public struct ProjectEditPlan: Sendable {
    public var project: DemoProject
    public var direct: [ProjectEditReference]
    public var derived: [ProjectEditReference]
    public var created: [ProjectEditCreation]
}
