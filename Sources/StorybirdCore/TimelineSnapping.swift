import Foundation

public struct TimelineSnapCandidate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case playhead, clipBoundary = "clip_boundary", layerBoundary = "layer_boundary" }
    public var time: Double
    public var kind: Kind
    public var targetID: UUID?
    public init(time: Double, kind: Kind, targetID: UUID? = nil) {
        self.time = time; self.kind = kind; self.targetID = targetID
    }
    var priority: Int {
        switch kind { case .playhead: 0; case .clipBoundary: 1; case .layerBoundary: 2 }
    }
}

public enum TimelineSnapping {
    /// Chooses the smallest adjustment of either moving edge. Candidate kind
    /// and earlier-time priority are identical to a single-edge snap.
    public static func translation(start: Double, end: Double, delta: Double, tolerance: Double,
        candidates: [TimelineSnapCandidate], excluding: Set<UUID> = [], bypass: Bool = false
    ) -> (delta: Double, candidate: TimelineSnapCandidate?) {
        guard !bypass, delta != 0 else { return (delta, nil) }
        var options: [(Double, TimelineSnapCandidate)] = []
        for edge in [start, end] {
            if let candidate = nearest(to: edge + delta, tolerance: tolerance, candidates: candidates, excluding: excluding) {
                options.append((candidate.time - edge, candidate))
            }
        }
        guard let best = options.min(by: { a, b in
            let first = abs(a.0 - delta), second = abs(b.0 - delta)
            if abs(first - second) > 1e-9 { return first < second }
            return (a.1.priority, a.1.time) < (b.1.priority, b.1.time)
        }) else { return (delta, nil) }
        return (best.0, best.1)
    }

    /// The UI supplies its pixel-derived tolerance; agents can inspect these
    /// same seconds directly. No playhead, selection or project state is changed.
    public static func candidates(in project: DemoProject, playhead: Double? = nil) -> [TimelineSnapCandidate] {
        var result: [TimelineSnapCandidate] = []
        if let playhead, playhead.isFinite, (0...project.timelineDuration).contains(playhead) {
            result.append(TimelineSnapCandidate(time: playhead, kind: .playhead))
        }
        for item in VideoTimelineSchedule(project: project).items {
            if case let .clip(clip) = item {
                for time in [clip.projectStart, clip.projectEnd] {
                    result.append(TimelineSnapCandidate(time: time, kind: .clipBoundary, targetID: clip.clip.id))
                }
            }
        }
        func add(_ times: [Double], id: UUID) {
            result += times.map { TimelineSnapCandidate(time: $0, kind: .layerBoundary, targetID: id) }
        }
        for click in project.clicks {
            add([click.time, click.indicator.startTime, click.indicator.endTime, click.description.startTime,
                 click.description.endTime, click.cueSubtitle.startTime, click.cueSubtitle.endTime], id: click.id)
        }
        for layer in project.subtitles { add([layer.startTime, layer.endTime], id: layer.id) }
        for layer in project.narrations { add([layer.startTime, layer.endTime], id: layer.id) }
        for layer in project.effects { add([layer.startTime, layer.endTime], id: layer.id) }
        return Array(Set(result)).sorted {
            ($0.time, $0.priority, $0.targetID?.uuidString ?? "") < ($1.time, $1.priority, $1.targetID?.uuidString ?? "")
        }
    }

    /// Nearest first; equal distances prefer playhead, clip, then layer. Within
    /// one kind the earlier time wins. Bypass represents a temporary Option drag.
    public static func nearest(to time: Double, tolerance: Double, candidates: [TimelineSnapCandidate],
                               excluding: Set<UUID> = [], bypass: Bool = false) -> TimelineSnapCandidate? {
        guard !bypass, time.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }
        return candidates.filter {
            $0.time.isFinite && abs($0.time - time) <= tolerance && $0.targetID.map { !excluding.contains($0) } != false
        }.min { left, right in
            let a = abs(left.time - time), b = abs(right.time - time)
            // Source cadence conversion can introduce a final-bit difference
            // between distances that represent the same timeline boundary.
            if abs(a - b) > 1e-9 { return a < b }
            return (left.priority, left.time, left.targetID?.uuidString ?? "")
                < (right.priority, right.time, right.targetID?.uuidString ?? "")
        }
    }
}
