import Foundation

/// A fully opaque rectangle. Time ownership and spatial coordinates are
/// separate required choices; an anchor only exists for scene timing.
public struct MaskEffect: Codable, Identifiable, Hashable, Sendable {
    public enum CoordinateSpace: String, Codable, CaseIterable, Sendable { case content, canvas }
    public var id: UUID
    public var startTime: Double
    public var endTime: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var timingMode: LayerTimingMode
    public var coordinateSpace: CoordinateSpace
    public var colorHex: String
    public var sceneAnchor: LayerSceneAnchor?

    public init(id: UUID = UUID(), startTime: Double, endTime: Double,
                x: Double, y: Double, width: Double, height: Double,
                timingMode: LayerTimingMode, coordinateSpace: CoordinateSpace,
                colorHex: String = "#000000", sceneAnchor: LayerSceneAnchor? = nil) {
        self.id = id; self.startTime = startTime; self.endTime = endTime
        self.x = x; self.y = y; self.width = width; self.height = height
        self.timingMode = timingMode; self.coordinateSpace = coordinateSpace
        self.colorHex = colorHex; self.sceneAnchor = sceneAnchor
    }

    public var hasValidRectangle: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && width <= 1 - x && height <= 1 - y
    }
}

public enum MaskEditor {
    /// Creates a validated mask with an explicit time/space contract. A scene
    /// start must belong to a playable clip; no mask changes the source media.
    public static func create(in project: DemoProject, startTime: Double, endTime: Double,
                              x: Double, y: Double, width: Double, height: Double,
                              timingMode: LayerTimingMode, coordinateSpace: MaskEffect.CoordinateSpace,
                              colorHex: String = "#000000") throws -> DemoProject {
        let anchor = timingMode == .scene ? try SceneTiming.anchor(at: startTime, in: project) : nil
        let mask = MaskEffect(startTime: startTime, endTime: endTime, x: x, y: y, width: width, height: height,
            timingMode: timingMode, coordinateSpace: coordinateSpace, colorHex: colorHex, sceneAnchor: anchor)
        var result = project
        result.effects.append(.mask(mask))
        try VideoProjectValidator.validate(result)
        return result
    }

    /// Updates only declared fields and reanchors an explicitly moved scene
    /// start. Batch callers defer whole-project validation until all edits end.
    public static func update(_ id: UUID, in project: DemoProject,
                              values: [String: ProjectEditValue], validateResult: Bool = true) throws -> DemoProject {
        guard let index = project.effects.firstIndex(where: { $0.id == id }),
              case let .mask(original) = project.effects[index] else { throw DemoEffectEditError.effectNotFound }
        let fields = ProjectEditFields.effect(.mask(original))
        var value = try ProjectEditFields.patch(original, values: values, fields: fields)
        if value.timingMode == .project { value.sceneAnchor = nil }
        else if original.timingMode != value.timingMode || original.startTime != value.startTime || value.sceneAnchor == nil {
            value.sceneAnchor = try SceneTiming.anchor(at: value.startTime, in: project)
        }
        var result = project
        result.effects[index] = .mask(value)
        if let position = values["order_index"]?.number {
            guard let destination = Int(exactly: position) else {
                throw ProjectEditError(code: "invalid_value", targetID: id, property: "order_index",
                    allowedRange: "zero-based integer mask index", message: "Choose an integer mask order.")
            }
            result = try reorder(id, to: destination, in: result)
        }
        if validateResult { try VideoProjectValidator.validate(result) }
        return result
    }

    /// Permutes only mask slots. Non-mask effects keep their relative order;
    /// masks are still composited after every other layer in this mask order.
    public static func reorder(_ id: UUID, to destination: Int, in project: DemoProject) throws -> DemoProject {
        let slots = project.effects.indices.filter { project.effects[$0].isMask }
        var masks = slots.map { project.effects[$0] }
        guard let source = masks.firstIndex(where: { $0.id == id }), masks.indices.contains(destination) else {
            throw ProjectEditError(code: "invalid_value", targetID: id, property: "order_index",
                allowedRange: "0...\(max(0, masks.count - 1))", message: "Choose an existing position in the mask stack.")
        }
        let moving = masks.remove(at: source)
        masks.insert(moving, at: destination)
        var result = project
        for (slot, mask) in zip(slots, masks) { result.effects[slot] = mask }
        return result
    }
}

extension DemoEffect {
    public var isMask: Bool { if case .mask = self { true } else { false } }
}
