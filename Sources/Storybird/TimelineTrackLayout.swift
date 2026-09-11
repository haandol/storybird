import Foundation
import StorybirdCore

struct TimelineTrackSpan: Identifiable, Equatable {
    let id: UUID
    let start: Double
    let end: Double
}

struct TimelineTrack: Identifiable {
    enum Kind: String, Hashable {
        case video, click, subtitle, narration, effect, suggestion

        var supportsExpansion: Bool {
            self != .video && self != .suggestion
        }
    }
    let kind: Kind
    let title: String
    let symbol: String
    let spans: [TimelineTrackSpan]
    var rowIndex = 0
    var groupCount = 0
    var isGroupHeader = false
    var id: String { "\(kind.rawValue)-\(rowIndex)" }
}

enum TimelineTrackLayout {
    /// Reuses rows for non-overlapping layers by default. Expansion affects only
    /// the requested kinds, leaving every layer's identity and timing intact.
    static func rows(
        in project: DemoProject, expandedKinds: Set<TimelineTrack.Kind> = []
    ) -> [TimelineTrack] {
        var rows = [TimelineTrack(kind: .video, title: "Video", symbol: "film", spans: clipSpans(in: project))]
        let groups: [(TimelineTrack.Kind, String, String, [TimelineTrackSpan])] = [
            (.click, "Clicks", "cursorarrow.click", clickSpans(in: project)),
            (.subtitle, "Subtitles", "captions.bubble.fill", subtitleSpans(in: project)),
            (.narration, "Audio", "waveform", narrationSpans(in: project)),
            (.effect, "Effects", "wand.and.stars", effectSpans(in: project))
        ]
        for (kind, title, symbol, spans) in groups {
            let lanes = spans.isEmpty ? [[]]
                : expandedKinds.contains(kind) ? spans.map { [$0] } : packedRows(spans)
            for (index, lane) in lanes.enumerated() {
                rows.append(TimelineTrack(
                    kind: kind, title: index == 0 ? title : "\(title) \(index + 1)",
                    symbol: symbol, spans: lane, rowIndex: index,
                    groupCount: spans.count, isGroupHeader: index == 0
                ))
            }
        }
        rows.append(TimelineTrack(
            kind: .suggestion, title: "Suggestions", symbol: "sparkles", spans: suggestionSpans(in: project)
        ))
        return rows
    }

    /// Processes starts in deterministic order and reuses the first available
    /// lane. Touching endpoints share a lane; a new lane means all others overlap.
    static func packedRows(_ spans: [TimelineTrackSpan]) -> [[TimelineTrackSpan]] {
        let sorted = spans.enumerated().sorted {
            if $0.element.start != $1.element.start { return $0.element.start < $1.element.start }
            return $0.offset < $1.offset
        }.map(\.element)
        var rows: [[TimelineTrackSpan]] = []
        for span in sorted {
            if let index = rows.firstIndex(where: { $0.last!.end <= span.start }) {
                rows[index].append(span)
            } else {
                rows.append([span])
            }
        }
        return rows
    }

    /// Uses the canonical edited schedule so cards and speed changes leave every track aligned.
    static func clipSpans(in project: DemoProject) -> [TimelineTrackSpan] {
        VideoTimelineSchedule(project: project).items.compactMap { item in
            guard case let .clip(value) = item else { return nil }
            return TimelineTrackSpan(
                id: value.clip.id,
                start: value.projectStart,
                end: value.projectEnd
            )
        }
    }

    /// Shows the complete Click Cue lifetime as one selectable timeline block.
    static func clickSpans(in project: DemoProject) -> [TimelineTrackSpan] {
        let duration = project.timelineDuration
        return project.clicks.map { click in
            boundedSpan(
                id: click.id,
                start: min(
                    click.indicator.startTime,
                    click.description.startTime,
                    click.cueSubtitle.startTime
                ),
                end: max(
                    click.indicator.endTime,
                    click.description.endTime,
                    click.cueSubtitle.endTime
                ),
                duration: duration
            )
        }
    }

    static func subtitleSpans(in project: DemoProject) -> [TimelineTrackSpan] {
        let duration = project.timelineDuration
        return project.subtitles.map {
            boundedSpan(
                id: $0.id,
                start: $0.startTime,
                end: $0.endTime,
                duration: duration
            )
        }
    }

    static func narrationSpans(in project: DemoProject) -> [TimelineTrackSpan] {
        let duration = project.timelineDuration
        return project.narrations.map {
            boundedSpan(
                id: $0.id,
                start: $0.startTime,
                end: $0.endTime,
                duration: duration
            )
        }
    }

    static func effectSpans(in project: DemoProject) -> [TimelineTrackSpan] {
        let duration = project.timelineDuration
        return project.effects.map {
            boundedSpan(
                id: $0.id,
                start: $0.startTime,
                end: $0.endTime,
                duration: duration
            )
        }
    }

    static func suggestionSpans(
        in project: DemoProject
    ) -> [TimelineTrackSpan] {
        let duration = project.timelineDuration
        return project.suggestions.map {
            boundedSpan(
                id: $0.id,
                start: $0.splitTime,
                end: $0.splitTime + 0.12,
                duration: duration
            )
        }
    }

    /// Clamps only to project bounds. Inventing a minimum duration here would
    /// make valid, touching short layers appear to overlap during row packing.
    private static func boundedSpan(
        id: UUID,
        start: Double,
        end: Double,
        duration: Double
    ) -> TimelineTrackSpan {
        let upperBound = max(duration, 0.001)
        let boundedStart = min(max(start, 0), upperBound)
        let boundedEnd = min(
            max(end, boundedStart),
            upperBound
        )
        return TimelineTrackSpan(
            id: id,
            start: boundedStart,
            end: max(boundedEnd, boundedStart)
        )
    }
}

/// The cache belongs to one editor and retains only its latest value. Compare
/// actual data, not revision alone: unsaved bindings and undo can reuse a revision.
@MainActor
final class TimelineTrackCache {
    private var cached: TimelineTrackSnapshot?

    func snapshot(project: DemoProject, expandedKinds: Set<TimelineTrack.Kind>) -> TimelineTrackSnapshot {
        if let cached, cached.project == project, cached.expandedKinds == expandedKinds {
            return cached
        }
        let value = TimelineTrackSnapshot(project: project, expandedKinds: expandedKinds)
        cached = value
        return value
    }
}

@MainActor
final class TimelineTrackSnapshot {
    let project: DemoProject
    let expandedKinds: Set<TimelineTrack.Kind>
    let rows: [TimelineTrack]
    let duration: Double
    let clips: [UUID: VideoClip]
    let clicks: [UUID: TimedPointerClick]
    let subtitles: [UUID: TimedSubtitle]
    let narrations: [UUID: NarrationClip]
    let effects: [UUID: DemoEffect]
    let suggestions: [UUID: ClickEditSuggestion]

    init(project: DemoProject, expandedKinds: Set<TimelineTrack.Kind>) {
        self.project = project
        self.expandedKinds = expandedKinds
        rows = TimelineTrackLayout.rows(in: project, expandedKinds: expandedKinds)
        duration = project.timelineDuration
        clips = Self.index(project.clips)
        clicks = Self.index(project.clicks)
        subtitles = Self.index(project.subtitles)
        narrations = Self.index(project.narrations)
        effects = Self.index(project.effects)
        suggestions = Self.index(project.suggestions)
    }

    private static func index<Value: Identifiable>(_ values: [Value]) -> [Value.ID: Value] {
        Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
