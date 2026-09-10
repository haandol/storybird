import Foundation

public enum LayerTimingMode: String, Codable, CaseIterable, Sendable {
    case project, scene
}

public struct LayerSceneAnchor: Codable, Hashable, Sendable {
    public var clipID: UUID
    public var sourceTime: Double
    public var clipOffset: Double

    public init(clipID: UUID, sourceTime: Double, clipOffset: Double) {
        self.clipID = clipID
        self.sourceTime = sourceTime
        self.clipOffset = clipOffset
    }
}

public enum SceneTiming {
    /// Anchors a playable start frame; cards and the final endpoint have no owner.
    public static func anchor(at time: Double, in project: DemoProject) throws -> LayerSceneAnchor {
        guard time.isFinite, time >= 0, time < project.timelineDuration,
              let location = VideoTimelineSchedule(project: project).sourceLocation(at: time) else {
            throw VideoTimelineEditError.invalidScenePlacement
        }
        return LayerSceneAnchor(
            clipID: location.clipID, sourceTime: location.sourceTime, clipOffset: location.clipOffset
        )
    }

    /// Resolves the exact owner, never another clip displaying the same frame.
    /// A missing owner or trimmed-away start produces nil.
    public static func time(for anchor: LayerSceneAnchor, in project: DemoProject) -> Double? {
        guard anchor.sourceTime.isFinite, anchor.clipOffset.isFinite, anchor.clipOffset >= 0 else { return nil }
        for item in VideoTimelineSchedule(project: project).items {
            guard case let .clip(scheduled) = item, scheduled.clip.id == anchor.clipID else { continue }
            let clip = scheduled.clip
            if clip.kind == .video {
                guard anchor.sourceTime >= clip.sourceStart, anchor.sourceTime < clip.sourceEnd else { return nil }
                return scheduled.projectStart + (anchor.sourceTime - clip.sourceStart) / clip.playbackRate
            }
            guard anchor.clipOffset < clip.freezeDuration,
                  abs(anchor.sourceTime - clip.sourceStart) < 0.001 else { return nil }
            return scheduled.projectStart + anchor.clipOffset
        }
        return nil
    }

    /// Moves starts without changing speech or subtitle duration. The project
    /// writer rejects any resulting overlap or overflow as one failed edit.
    public static func remap(_ project: DemoProject) -> DemoProject {
        var result = project
        result.narrations = project.narrations.compactMap { narration in
            guard let anchor = narration.sceneAnchor else { return narration }
            guard let time = time(for: anchor, in: project) else { return nil }
            var updated = narration
            updated.startTime = time
            return updated
        }.sorted { $0.startTime < $1.startTime }
        result.subtitles = project.subtitles.compactMap { subtitle in
            guard let anchor = subtitle.sceneAnchor else { return subtitle }
            guard let time = time(for: anchor, in: project) else { return nil }
            var updated = subtitle
            updated.endTime = time + subtitle.endTime - subtitle.startTime
            updated.startTime = time
            return updated
        }
        return result
    }

    /// Assigns a boundary start to exactly one child when its owner is split.
    public static func transferSplit(
        in project: DemoProject, originalID: UUID, left: VideoClip, right: VideoClip
    ) -> DemoProject {
        var result = project
        for index in result.narrations.indices {
            if var anchor = result.narrations[index].sceneAnchor, anchor.clipID == originalID {
                anchor.clipID = anchor.sourceTime < right.sourceStart ? left.id : right.id
                result.narrations[index].sceneAnchor = anchor
            }
        }
        for index in result.subtitles.indices {
            if var anchor = result.subtitles[index].sceneAnchor, anchor.clipID == originalID {
                anchor.clipID = anchor.sourceTime < right.sourceStart ? left.id : right.id
                result.subtitles[index].sceneAnchor = anchor
            }
        }
        return result
    }

    /// Explicit inspector retiming chooses a new owner. A clip/card edit already
    /// transforms times and must not be interpreted as manual retiming.
    public static func reanchorTimeEdits(from old: DemoProject, to edited: DemoProject) throws -> DemoProject {
        guard old.clips == edited.clips, old.effects == edited.effects else { return edited }
        var result = edited
        for index in result.narrations.indices {
            let value = result.narrations[index]
            if let previous = old.narrations.first(where: { $0.id == value.id }),
               value.sceneAnchor != nil, value.sceneAnchor == previous.sceneAnchor,
               value.startTime != previous.startTime {
                result.narrations[index].sceneAnchor = try anchor(at: value.startTime, in: result)
            }
        }
        for index in result.subtitles.indices {
            let value = result.subtitles[index]
            if let previous = old.subtitles.first(where: { $0.id == value.id }),
               value.sceneAnchor != nil, value.sceneAnchor == previous.sceneAnchor,
               value.startTime != previous.startTime {
                result.subtitles[index].sceneAnchor = try anchor(at: value.startTime, in: result)
            }
        }
        return result
    }

    /// Rejects forged/stale anchors rather than silently altering stored speech.
    public static func validate(_ project: DemoProject) throws {
        for narration in project.narrations {
            if let anchor = narration.sceneAnchor {
                guard let time = time(for: anchor, in: project),
                      abs(time - narration.startTime) < 0.001 else {
                    throw VideoProjectValidationError.invalidNarration(narration.id, "Its scene anchor does not match its start. Refresh the edit context.")
                }
            }
        }
        for subtitle in project.subtitles {
            if let anchor = subtitle.sceneAnchor {
                guard let time = time(for: anchor, in: project),
                      abs(time - subtitle.startTime) < 0.001 else {
                    throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
                }
            }
        }
    }
}
