import Foundation

/// Projects source-normalized content through its clip's fit/fill placement.
/// Stored coordinates stay in the source; screen-fixed captions use the canvas.
public enum ProjectContentGeometry {
    public static func frame(in project: DemoProject, at time: Double) -> CGRect {
        let schedule = VideoTimelineSchedule(project: project)
        let item = schedule.items.first { time >= $0.projectStart && time < $0.projectEnd }
            ?? (time == project.timelineDuration ? schedule.items.last : nil)
        let clip: VideoClip?
        switch item {
        case let .clip(value): clip = value.clip
        case let .card(value): clip = value.sourceClip
        case nil: clip = nil
        }
        guard let clip, let asset = project.mediaAsset(for: clip), project.canvasSize.width > 0, project.canvasSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let canvas = project.canvasSize
        let placed = clip.placement.frame(source: CGSize(width: asset.width, height: asset.height), canvas: canvas)
        return CGRect(x: placed.minX / canvas.width, y: placed.minY / canvas.height,
            width: placed.width / canvas.width, height: placed.height / canvas.height)
    }

    public static func point(x: Double, y: Double, in project: DemoProject, at time: Double) -> VideoNormalizedPoint {
        let rect = frame(in: project, at: time)
        return VideoNormalizedPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    /// Inverse mapping for direct preview handles. The gesture captures one
    /// camera/placement snapshot so a moving handle does not chase its own edit.
    public static func sourcePoint(canvasX: Double, canvasY: Double, frame: CGRect,
                                   camera: VideoCameraPresentation) -> VideoNormalizedPoint {
        let x = camera.x + (canvasX - 0.5) / camera.scale
        let y = camera.y + (canvasY - 0.5) / camera.scale
        return VideoNormalizedPoint(x: (x - frame.minX) / frame.width, y: (y - frame.minY) / frame.height)
    }

    public static func click(_ original: TimedPointerClick, in project: DemoProject, at time: Double) -> TimedPointerClick {
        var value = original
        let point = point(x: original.x, y: original.y, in: project, at: time)
        value.x = point.x; value.y = point.y
        let description = self.point(x: original.description.x, y: original.description.y, in: project, at: time)
        value.description.x = description.x; value.description.y = description.y
        return value
    }

    public static func spotlight(_ original: SpotlightEffect, in project: DemoProject, at time: Double) -> SpotlightEffect {
        let frame = frame(in: project, at: time)
        let camera = VideoOverlayPresentation.camera(in: project, at: time)
        let point = camera.transform(x: frame.minX + original.x * frame.width, y: frame.minY + original.y * frame.height)
        var result = original
        result.x = point.x; result.y = point.y
        result.width *= frame.width * camera.scale
        result.height *= frame.height * camera.scale
        return result
    }
}
