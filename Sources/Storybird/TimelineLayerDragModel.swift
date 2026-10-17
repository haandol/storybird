import StorybirdCore
import SwiftUI

@MainActor
final class TimelineLayerDragModel: ObservableObject {
    @Published private(set) var target: TimelineLayerTarget?
    @Published private(set) var delta: Double = 0
    @Published private(set) var guide: TimelineSnapCandidate?
    private var targets: [ProjectEditReference] = []
    private var baseline: DemoProject?
    private var canvasWidth: Double = 1

    /// Captures the project once per gesture. Further pointer movement changes
    /// only the preview offset, never the project or its undo history.
    func update(
        target: TimelineLayerTarget, translation: Double, canvasWidth: Double, project: DemoProject,
        selection: Set<ProjectEditReference> = [], playhead: Double? = nil,
        snapEnabled: Bool = false, bypassSnap: Bool = false
    ) {
        guard translation.isFinite, canvasWidth.isFinite, canvasWidth > 0 else { return }
        if self.target == nil {
            self.target = target
            baseline = project
            self.canvasWidth = canvasWidth
            targets = selection.contains(target.editReference) && selection.allSatisfy { $0.target != .clip && $0.target != .project }
                ? ProjectEditPlanner.references(in: project).filter { selection.contains($0) } : [target.editReference]
        }
        guard self.target == target, let baseline else { return }
        delta = translation / self.canvasWidth * baseline.timelineDuration
        guide = nil
        if snapEnabled {
            let bounds = targets.compactMap { range(of: $0, in: baseline) }
            if let start = bounds.map(\.lowerBound).min(), let end = bounds.map(\.upperBound).max() {
                let snapped = TimelineSnapping.translation(start: start, end: end, delta: delta,
                    tolerance: 8 / self.canvasWidth * baseline.timelineDuration,
                    candidates: TimelineSnapping.candidates(in: baseline, playhead: playhead),
                    excluding: Set(targets.map(\.id)), bypass: bypassSnap)
                delta = snapped.delta
                guide = snapped.candidate
            }
        }
    }

    func includes(_ target: TimelineLayerTarget) -> Bool { targets.contains(target.editReference) }

    private func range(of ref: ProjectEditReference, in project: DemoProject) -> ClosedRange<Double>? {
        switch ref.target {
        case .click:
            guard let click = project.clicks.first(where: { $0.id == ref.id }) else { return nil }
            let start = min(click.indicator.startTime, click.description.startTime, click.cueSubtitle.startTime)
            let end = max(click.indicator.endTime, click.description.endTime, click.cueSubtitle.endTime)
            return start...end
        case .subtitle: return project.subtitles.first { $0.id == ref.id }.map { $0.startTime...$0.endTime }
        case .audio: return project.narrations.first { $0.id == ref.id }.map { $0.startTime...$0.endTime }
        case .effect: return project.effects.first { $0.id == ref.id }.map { $0.startTime...$0.endTime }
        case .clip, .project: return nil
        }
    }

    /// Commits against the current project so same-revision suggestion and asset
    /// updates survive the gesture. Changed output revisions and failed writes
    /// leave the stored project and undo unchanged.
    func finish(in store: AppStore) {
        defer { cancel() }
        guard target != nil, let baseline, delta != 0 else { return }
        do {
            _ = try store.editProject(projectID: baseline.id, expectedRevision: baseline.revision,
                edits: targets.map { ProjectEdit(target: $0.target, id: $0.id, action: .move, values: ["delta": .number(delta)]) })
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// Ends an interrupted gesture without applying its preview.
    func cancel() {
        target = nil
        baseline = nil
        delta = 0
        guide = nil
        targets = []
    }
}
