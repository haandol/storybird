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
        SceneIndex(project: project).time(for: anchor)
    }

    /// One immutable schedule serves an entire remap or validation. Rebuilding
    /// it for each linked layer makes a large edit quadratic in clip count.
    private struct SceneIndex {
        let clips: [UUID: VideoTimelineSchedule.ScheduledClip]

        init(project: DemoProject) {
            var clips: [UUID: VideoTimelineSchedule.ScheduledClip] = [:]
            for item in VideoTimelineSchedule(project: project).items {
                guard case let .clip(scheduled) = item,
                      clips[scheduled.clip.id] == nil else { continue }
                // Keep first-owner lookup behavior even before duplicate-ID
                // validation; malformed input must not trap in a dictionary.
                clips[scheduled.clip.id] = scheduled
            }
            self.clips = clips
        }

        func time(for anchor: LayerSceneAnchor) -> Double? {
            guard anchor.sourceTime.isFinite, anchor.clipOffset.isFinite, anchor.clipOffset >= 0,
                  let scheduled = clips[anchor.clipID] else { return nil }
            let clip = scheduled.clip
            if clip.kind == .video {
                guard anchor.sourceTime >= clip.sourceStart, anchor.sourceTime < clip.sourceEnd else { return nil }
                return scheduled.projectStart + (anchor.sourceTime - clip.sourceStart) / clip.playbackRate
            }
            guard anchor.clipOffset < clip.freezeDuration,
                  abs(anchor.sourceTime - clip.sourceStart) < 0.001 else { return nil }
            return scheduled.projectStart + anchor.clipOffset
        }
    }

    private static func sceneIndexIfNeeded(_ project: DemoProject) -> SceneIndex? {
        guard project.narrations.contains(where: { $0.sceneAnchor != nil })
            || project.subtitles.contains(where: { $0.sceneAnchor != nil }) else { return nil }
        return SceneIndex(project: project)
    }

    /// Moves starts without changing speech or subtitle duration. The project
    /// writer rejects project overflow as one failed edit; audio overlap is allowed.
    public static func remap(_ project: DemoProject) -> DemoProject {
        let index = sceneIndexIfNeeded(project)
        var result = project
        result.narrations = project.narrations.compactMap { narration in
            guard let anchor = narration.sceneAnchor else { return narration }
            guard let time = index?.time(for: anchor) else { return nil }
            var updated = narration
            updated.startTime = time
            return updated
        }.sorted { $0.startTime < $1.startTime }
        result.subtitles = project.subtitles.compactMap { subtitle in
            guard let anchor = subtitle.sceneAnchor else { return subtitle }
            guard let time = index?.time(for: anchor) else { return nil }
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
        let oldNarrations = Dictionary(old.narrations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldSubtitles = Dictionary(old.subtitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = edited
        for index in result.narrations.indices {
            let value = result.narrations[index]
            if let previous = oldNarrations[value.id],
               value.sceneAnchor != nil, value.sceneAnchor == previous.sceneAnchor,
               value.startTime != previous.startTime {
                result.narrations[index].sceneAnchor = try anchor(at: value.startTime, in: result)
            }
        }
        for index in result.subtitles.indices {
            let value = result.subtitles[index]
            if let previous = oldSubtitles[value.id],
               value.sceneAnchor != nil, value.sceneAnchor == previous.sceneAnchor,
               value.startTime != previous.startTime {
                result.subtitles[index].sceneAnchor = try anchor(at: value.startTime, in: result)
            }
        }
        return result
    }

    /// Rejects forged/stale anchors rather than silently altering stored speech.
    public static func validate(_ project: DemoProject) throws {
        let index = sceneIndexIfNeeded(project)
        for narration in project.narrations {
            if let anchor = narration.sceneAnchor {
                guard let time = index?.time(for: anchor),
                      abs(time - narration.startTime) < 0.001 else {
                    throw VideoProjectValidationError.invalidNarration(narration.id, "Its scene anchor does not match its start. Refresh the edit context.")
                }
            }
        }
        for subtitle in project.subtitles {
            if let anchor = subtitle.sceneAnchor {
                guard let time = index?.time(for: anchor),
                      abs(time - subtitle.startTime) < 0.001 else {
                    throw VideoProjectValidationError.invalidSubtitle(subtitle.id)
                }
            }
        }
    }
}
