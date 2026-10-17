import StorybirdCore
import Foundation

/// Selection interpretation is shared by the toolbar/menu and local keys.
/// The returned edits still use the same public target/action/value contract.
enum TimelineSelectionCommands {
    static func duplicates(targets: [ProjectEditReference], in project: DemoProject, at playhead: Double) -> [ProjectEdit] {
        let selectedClips = Set(targets.filter { $0.target == .clip }.map(\.id))
        var order = project.clips.map(\.id)
        var edits: [ProjectEdit] = []
        for clip in project.clips where selectedClips.contains(clip.id) {
            guard let index = order.firstIndex(of: clip.id) else { continue }
            edits.append(ProjectEdit(target: .clip, id: clip.id, action: .duplicate, values: ["destination_index": .number(Double(index + 1))]))
            order.insert(UUID(), at: index + 1)
        }
        let layers = targets.filter { ref in
            ref.target != .clip && ProjectEditPlanner.sceneOwner(of: ref, in: project).map { !selectedClips.contains($0) } != false
        }
        let starts = layers.compactMap { startTime($0, in: project) }
        let delta = playhead - (starts.min() ?? playhead)
        for ref in layers {
            let start: Double
            if let card = project.effects.first(where: { $0.id == ref.id && $0.isFullScreenCard }) { start = card.endTime }
            else { start = (startTime(ref, in: project) ?? 0) + delta }
            edits.append(ProjectEdit(target: ref.target, id: ref.id, action: .duplicate, values: ["start_time": .number(start)]))
        }
        return edits
    }

    private static func startTime(_ ref: ProjectEditReference, in project: DemoProject) -> Double? {
        switch ref.target {
        case .subtitle: project.subtitles.first { $0.id == ref.id }?.startTime
        case .click: project.clicks.first { $0.id == ref.id }?.time
        case .audio: project.narrations.first { $0.id == ref.id }?.startTime
        case .effect: project.effects.first { $0.id == ref.id }?.startTime
        case .clip, .project: nil
        }
    }
}
