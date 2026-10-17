import Foundation

public struct MaskDrawInstruction: Identifiable, Sendable {
    public let id: UUID
    /// Top-left coordinates in output-canvas pixels, rounded outward.
    public let pixelRect: CGRect
    public let rgb: UInt32
    public var red: Double { Double((rgb >> 16) & 255) / 255 }
    public var green: Double { Double((rgb >> 8) & 255) / 255 }
    public var blue: Double { Double(rgb & 255) / 255 }
}

public enum MaskGeometry {
    /// Unclipped geometry also positions native handles in the same source or
    /// canvas space; pixel coverage is rounded outward only when drawing.
    public static func normalizedRect(for value: MaskEffect, in project: DemoProject, at time: Double) -> CGRect {
        var rect = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
        if value.coordinateSpace == .content {
            let placement = ProjectContentGeometry.frame(in: project, at: time)
            let camera = VideoOverlayPresentation.camera(in: project, at: time)
            let origin = camera.transform(x: placement.minX + value.x * placement.width,
                y: placement.minY + value.y * placement.height)
            rect = CGRect(x: origin.x, y: origin.y, width: value.width * placement.width * camera.scale,
                height: value.height * placement.height * camera.scale)
        }
        return rect
    }

    /// Validates every required mask before returning the active ordered stack.
    /// Invalid metadata must never degrade into a successful unmasked preview.
    public static func layers(in project: DemoProject, at time: Double) throws -> [MaskDrawInstruction] {
        let masks = project.effects.compactMap { effect -> MaskEffect? in
            if case let .mask(value) = effect { return value }; return nil
        }
        guard !masks.isEmpty else { return [] }
        let canvas = project.canvasSize
        guard time.isFinite, canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
            throw VideoProjectValidationError.invalidCanvas
        }
        var ids = Set<UUID>()
        var result: [MaskDrawInstruction] = []
        for value in masks {
            guard ids.insert(value.id).inserted, value.hasValidRectangle,
                  value.startTime.isFinite, value.endTime.isFinite, value.startTime >= 0,
                  value.startTime < value.endTime, value.endTime <= project.timelineDuration,
                  value.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
                  let rgb = UInt32(value.colorHex.dropFirst(), radix: 16) else {
                throw VideoProjectValidationError.invalidEffect(value.id)
            }
            if value.timingMode == .scene {
                guard let anchor = value.sceneAnchor, let start = SceneTiming.time(for: anchor, in: project),
                      abs(start - value.startTime) < 0.001 else { throw VideoProjectValidationError.invalidEffect(value.id) }
            } else if value.sceneAnchor != nil { throw VideoProjectValidationError.invalidEffect(value.id) }
            guard value.startTime <= time, time <= value.endTime else { continue }
            let rect = normalizedRect(for: value, in: project, at: time)
            let left = floor(rect.minX * canvas.width), top = floor(rect.minY * canvas.height)
            let right = max(ceil(rect.maxX * canvas.width), left + 1)
            let bottom = max(ceil(rect.maxY * canvas.height), top + 1)
            guard [left, top, right, bottom].allSatisfy(\.isFinite) else { throw VideoProjectValidationError.invalidEffect(value.id) }
            let clipped = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                .intersection(CGRect(origin: .zero, size: canvas))
            result.append(MaskDrawInstruction(id: value.id, pixelRect: clipped.isNull ? .zero : clipped, rgb: rgb))
        }
        return result
    }
}
